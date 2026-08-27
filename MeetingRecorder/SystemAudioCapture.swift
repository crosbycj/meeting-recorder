import AudioToolbox
import AVFoundation
import Foundation

enum SystemAudioCaptureError: LocalizedError {
    case audioRecordingPermissionDenied
    case tapCreationFailed(String)
    case aggregateDeviceCreationFailed(String)
    case captureStartFailed(String)
    case captureStopFailed(String)
    case writerPreparationFailed(String)
    case writerFinalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioRecordingPermissionDenied:
            return "Screen & System Audio Recording permission is not granted. Allow access in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .tapCreationFailed(let message):
            return "Failed to create audio process tap: \(message)"
        case .aggregateDeviceCreationFailed(let message):
            return "Failed to create aggregate audio device: \(message)"
        case .captureStartFailed(let message):
            return "Failed to start system audio capture: \(message)"
        case .captureStopFailed(let message):
            return "Failed to stop system audio capture: \(message)"
        case .writerPreparationFailed(let message):
            return "Failed to prepare system audio writer: \(message)"
        case .writerFinalizationFailed(let message):
            return "Failed to finalize system audio writer: \(message)"
        }
    }
}

final class SystemAudioCapture {
    typealias SilenceDetectedHandler = @Sendable () -> Void
    typealias AudioActivityDetectedHandler = @Sendable () -> Void

    private static let silenceRMSThreshold: Float = 0.001
    private static let silenceTickLogInterval = 5
    private static let rmsDiagnosticLogInterval: TimeInterval = 5.0
    private static let nonSilentLogInterval: TimeInterval = 10.0

    let outputURL: URL

    private let sampleQueue = DispatchQueue(label: "MeetingRecorder.SystemAudioCapture.SampleQueue")
    private let stateQueue = DispatchQueue(label: "MeetingRecorder.SystemAudioCapture.StateQueue")
    private let writerQueue = DispatchQueue(label: "MeetingRecorder.SystemAudioCapture.WriterQueue")

    // CoreAudio process tap state
    private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var tapFormat: AVAudioFormat?

    // Silence tracking state (all accessed on stateQueue)
    private var lastNonSilentTime: Date?
    private var didNotifySilenceForCurrentPeriod = false
    private var silenceCheckTimer: DispatchSourceTimer?
    private var silenceCheckTickCount = 0
    private var lastNonSilentDiagnosticLogTime: Date = .distantPast
    private var lastRMSDiagnosticLogTime: Date = .distantPast
    private var hasLoggedMissingRMS = false
    private var onSilenceDetectedHandler: SilenceDetectedHandler?
    private var onAudioActivityDetectedHandler: AudioActivityDetectedHandler?
    private var silenceDurationTrigger: TimeInterval = 60.0
    private(set) var isRunning = false

    var onSilenceDetected: SilenceDetectedHandler? {
        get {
            stateQueue.sync { onSilenceDetectedHandler }
        }
        set {
            stateQueue.sync { onSilenceDetectedHandler = newValue }
        }
    }

    var onAudioActivityDetected: AudioActivityDetectedHandler? {
        get {
            stateQueue.sync { onAudioActivityDetectedHandler }
        }
        set {
            stateQueue.sync { onAudioActivityDetectedHandler = newValue }
        }
    }

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func setSilenceDuration(_ duration: TimeInterval) {
        stateQueue.sync {
            self.silenceDurationTrigger = duration
        }
    }

    func start() async throws {
        guard !isRunning else {
            return
        }

        // Clean up any existing output file
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Step 1: Get our own process's AudioObjectID to exclude from the tap
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownObjectID = try getProcessObjectID(for: ownPID)

        // Step 2: Create a process tap that captures all system audio except our process
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapErr == noErr else {
            throw SystemAudioCaptureError.audioRecordingPermissionDenied
        }
        processTapID = tapID

        // Step 3: Read the tap's audio stream format
        var streamDesc = try readTapStreamDescription(tapID: tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to create AVAudioFormat from tap stream description")
        }
        tapFormat = format

        // Step 4: Get the default system output device UID
        let systemOutputID = try getDefaultSystemOutputDevice()
        let outputUID = try getDeviceUID(for: systemOutputID)

        // Step 5: Create an aggregate device that includes the tap
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingRecorder-SystemAudioTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var aggDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggDeviceID)
        guard aggErr == noErr else {
            throw SystemAudioCaptureError.aggregateDeviceCreationFailed("Error code: \(aggErr)")
        }
        aggregateDeviceID = aggDeviceID

        // Step 6: Create the audio file for writing
        let settings: [String: Any] = [
            AVFormatIDKey: streamDesc.mFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: format.isInterleaved
            )
        } catch {
            throw SystemAudioCaptureError.writerPreparationFailed(error.localizedDescription)
        }

        // Step 7: Create the IOProc and start the device
        var procID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            sampleQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleIOProcCallback(inInputData: inInputData, format: format)
        }
        guard procErr == noErr, let procID else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to create device I/O proc: \(procErr)")
        }
        deviceProcID = procID

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to start audio device: \(startErr)")
        }

        // Step 8: Initialize state and start silence timer
        stateQueue.sync {
            self.isRunning = true
            self.lastNonSilentTime = Date()
            self.silenceCheckTickCount = 0
            self.lastNonSilentDiagnosticLogTime = .distantPast
            self.lastRMSDiagnosticLogTime = .distantPast
            self.hasLoggedMissingRMS = false
            self.didNotifySilenceForCurrentPeriod = false
        }

        UserDefaults.standard.set(true, forKey: "systemAudioCaptureSucceeded")

        startSilenceCheckTimer()
        let silenceDurationTrigger = stateQueue.sync { self.silenceDurationTrigger }
        NSLog(
            "MeetingRecorder: silence detection armed (duration=\(silenceDurationTrigger)s, rmsThreshold=\(Self.silenceRMSThreshold))"
        )
    }

    func stop() async throws {
        stopSilenceCheckTimer()

        // Set isRunning = false so IOProc callbacks will no-op
        stateQueue.sync {
            self.isRunning = false
        }

        // Stop the device (blocks until in-flight IOProc callbacks finish)
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let procID = deviceProcID {
            let stopErr = AudioDeviceStop(aggregateDeviceID, procID)
            if stopErr != noErr {
                NSLog("MeetingRecorder: warning: AudioDeviceStop returned \(stopErr)")
            }
        }

        // Drain pending writes before closing the file
        writerQueue.sync {}

        // Close the audio file (flushes remaining data)
        audioFile = nil

        // Destroy the IOProc
        if let procID = deviceProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }

        // Destroy the aggregate device
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        // Destroy the process tap
        if processTapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }

        tapFormat = nil
    }

    // MARK: - IOProc Callback

    private func handleIOProcCallback(inInputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
            return
        }

        // RMS is pure math — safe to compute on the real-time thread
        let rms = self.rmsAmplitude(for: buffer)

        // Copy the buffer so it survives past this callback (the IOProc buffer is transient)
        guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return
        }
        bufferCopy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = bufferCopy.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        }

        // Write to disk off the real-time thread
        writerQueue.async { [weak self] in
            guard let self else { return }
            if let file = self.audioFile {
                do {
                    try file.write(from: bufferCopy)
                } catch {
                    NSLog("MeetingRecorder: failed to write audio buffer: \(error.localizedDescription)")
                }
            }
        }

        // Update silence tracking state off the real-time thread
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.logRMSDiagnosticIfNeeded(rmsAmplitude: rms)
            let resumedFromSilence = self.updateSilenceTracking(rmsAmplitude: rms)
            if resumedFromSilence {
                self.onAudioActivityDetectedHandler?()
            }
        }
    }

    // MARK: - CoreAudio Helpers

    private func getProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let err = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(systemObject, &address, qualifierSize, pidPtr, &size, &objectID)
        }
        guard err == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to translate PID to process object: \(err)")
        }
        return objectID
    }

    private func getDefaultSystemOutputDevice() throws -> AudioDeviceID {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard err == noErr else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to get default system output device: \(err)")
        }
        return deviceID
    }

    private func getDeviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to get device UID: \(err)")
        }
        return uid as String
    }

    private func readTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &desc)
        guard err == noErr else {
            throw SystemAudioCaptureError.captureStartFailed("Failed to read tap stream format: \(err)")
        }
        return desc
    }

    // MARK: - RMS Amplitude

    private func rmsAmplitude(for buffer: AVAudioPCMBuffer) -> Float? {
        guard let floatData = buffer.floatChannelData else {
            return nil
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else {
            return nil
        }

        var sumSquares: Double = 0.0
        var totalSamples = 0
        for channel in 0..<channelCount {
            let samples = floatData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                sumSquares += sample * sample
            }
            totalSamples += frameLength
        }
        guard totalSamples > 0 else {
            return nil
        }
        return Float(sqrt(sumSquares / Double(totalSamples)))
    }

    // MARK: - Silence Tracking

    private func updateSilenceTracking(
        rmsAmplitude: Float?
    ) -> Bool {
        guard let rmsAmplitude else {
            if !hasLoggedMissingRMS {
                hasLoggedMissingRMS = true
                NSLog("MeetingRecorder: RMS unavailable for system audio sample; silence detection is using wall-clock fallback")
            }
            return false
        }
        hasLoggedMissingRMS = false

        if rmsAmplitude >= Self.silenceRMSThreshold {
            let now = Date()
            let resumedFromSilence = didNotifySilenceForCurrentPeriod
            if now.timeIntervalSince(lastNonSilentDiagnosticLogTime) >= Self.nonSilentLogInterval {
                let dbFS = 20 * log10(max(Double(rmsAmplitude), 1e-9))
                NSLog(
                    "MeetingRecorder: non-silent system audio detected (rms=\(String(format: "%.5f", rmsAmplitude)), dbFS=\(String(format: "%.1f", dbFS)))"
                )
                lastNonSilentDiagnosticLogTime = now
            }
            lastNonSilentTime = now
            NSLog(
                "[SilenceDebug] SystemAudioCapture lastNonSilentTime reset from sample: rms=%.5f threshold=%.5f",
                Double(rmsAmplitude),
                Double(Self.silenceRMSThreshold)
            )
            didNotifySilenceForCurrentPeriod = false
            if resumedFromSilence {
                NSLog("MeetingRecorder: system audio activity resumed after a silence period")
            }
            return resumedFromSilence
        }

        return false
    }

    private func startSilenceCheckTimer() {
        stateQueue.sync {
            _ = stopSilenceCheckTimerLocked()

            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            NSLog("[SilenceDebug] SystemAudioCapture silence timer created")
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.handleSilenceCheckTimerTickOnStateQueue()
            }
            silenceCheckTimer = timer
            silenceCheckTickCount = 0
            timer.resume()
            NSLog("[SilenceDebug] SystemAudioCapture silence timer resumed")
        }
        NSLog("MeetingRecorder: silence check timer started")
    }

    private func stopSilenceCheckTimer() {
        let didStop = stateQueue.sync {
            stopSilenceCheckTimerLocked()
        }
        if didStop {
            NSLog("MeetingRecorder: silence check timer stopped")
        }
    }

    private func stopSilenceCheckTimerLocked() -> Bool {
        guard let silenceCheckTimer else {
            return false
        }
        silenceCheckTimer.setEventHandler {}
        silenceCheckTimer.cancel()
        NSLog("[SilenceDebug] SystemAudioCapture silence timer cancelled")
        self.silenceCheckTimer = nil
        return true
    }

    private func handleSilenceCheckTimerTickOnStateQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))

        let now = Date()
        silenceCheckTickCount += 1

        guard isRunning else {
            NSLog("[SilenceDebug] SystemAudioCapture timer tick %d skipped: capture not running", silenceCheckTickCount)
            return
        }

        if lastNonSilentTime == nil {
            lastNonSilentTime = now
            NSLog("[SilenceDebug] SystemAudioCapture timer initialized lastNonSilentTime on tick %d", silenceCheckTickCount)
        }

        guard let lastNonSilentTime else {
            return
        }

        let elapsed = now.timeIntervalSince(lastNonSilentTime)
        let isSilent = elapsed >= silenceDurationTrigger
        NSLog(
            "[SilenceDebug] SystemAudioCapture timer tick: elapsed=%.1fs threshold=%.1fs state=%@ didNotify=%@ callbackNil=%@",
            elapsed,
            silenceDurationTrigger,
            isSilent ? "silent" : "active",
            didNotifySilenceForCurrentPeriod ? "YES" : "NO",
            onSilenceDetectedHandler == nil ? "YES" : "NO"
        )

        guard elapsed >= silenceDurationTrigger,
              !didNotifySilenceForCurrentPeriod else {
            return
        }

        didNotifySilenceForCurrentPeriod = true
        let silenceCallbackToNotify = onSilenceDetectedHandler
        NSLog(
            "[SilenceDebug] SystemAudioCapture firing onSilenceDetected callback: elapsed=%.1fs callbackNil=%@",
            elapsed,
            silenceCallbackToNotify == nil ? "YES" : "NO"
        )
        silenceCallbackToNotify?()
    }

    private func logRMSDiagnosticIfNeeded(rmsAmplitude: Float?) {
        dispatchPrecondition(condition: .onQueue(stateQueue))

        let now = Date()
        guard now.timeIntervalSince(lastRMSDiagnosticLogTime) >= Self.rmsDiagnosticLogInterval else {
            return
        }
        lastRMSDiagnosticLogTime = now

        guard let rmsAmplitude else {
            NSLog(
                "[SilenceDebug] SystemAudioCapture sample RMS: unavailable threshold=%.5f",
                Double(Self.silenceRMSThreshold)
            )
            return
        }

        let classification = rmsAmplitude >= Self.silenceRMSThreshold ? "ABOVE_OR_EQUAL_THRESHOLD" : "BELOW_THRESHOLD"
        NSLog(
            "[SilenceDebug] SystemAudioCapture sample RMS: rms=%.5f threshold=%.5f classification=%@",
            Double(rmsAmplitude),
            Double(Self.silenceRMSThreshold),
            classification
        )
    }
}
