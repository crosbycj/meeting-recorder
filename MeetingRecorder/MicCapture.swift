@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - CoreAudio Device Enumeration

func availableInputDevices() -> [(name: String, uid: String)] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
        return []
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    guard deviceCount > 0 else { return [] }

    var deviceIDs = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: deviceCount)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
        return []
    }

    var result: [(name: String, uid: String)] = []
    for deviceID in deviceIDs where deviceID != AudioObjectID(kAudioObjectUnknown) {
        // Check input channel count
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr else {
            continue
        }
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(streamSize))
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else {
            continue
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard inputChannels > 0 else { continue }

        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() as String? else {
            continue
        }

        // Get device UID
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr,
              let uid = uidRef?.takeRetainedValue() as String? else {
            continue
        }

        result.append((name: name, uid: uid))
    }
    return result
}

func systemDefaultInputDevice() -> (name: String, uid: String)? {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID) == noErr,
          deviceID != AudioDeviceID(kAudioObjectUnknown) else {
        return nil
    }

    // Get name
    var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var nameRef: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
          let name = nameRef?.takeRetainedValue() as String? else {
        return nil
    }

    // Get UID
    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uidRef: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr,
          let uid = uidRef?.takeRetainedValue() as String? else {
        return nil
    }

    return (name: name, uid: uid)
}

func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var uidCF: CFString = uid as CFString
    let status = withUnsafeMutablePointer(to: &uidCF) { uidPointer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            uidPointer,
            &dataSize,
            &deviceID
        )
    }
    guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
        return nil
    }
    return deviceID
}

enum MicCaptureError: LocalizedError {
    case microphonePermissionDenied
    case microphoneInputUnavailable
    case writerNotPrepared

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is not granted. Allow access in System Settings > Privacy & Security > Microphone."
        case .microphoneInputUnavailable:
            return "No microphone input is available."
        case .writerNotPrepared:
            return "Failed to prepare microphone audio writer."
        }
    }
}

final class MicCapture {
    typealias SilenceDetectedHandler = @Sendable () -> Void
    typealias AudioActivityDetectedHandler = @Sendable () -> Void

    private static let silenceRMSThreshold: Float = 0.02
    private static let silenceTickLogInterval = 5
    private static let rmsDiagnosticLogInterval: TimeInterval = 5.0
    private static let nonSilentLogInterval: TimeInterval = 10.0

    let outputURL: URL

    private let audioEngine = AVAudioEngine()
    private let fileLock = NSLock()
    private let stateQueue = DispatchQueue(label: "MeetingRecorder.MicCapture.StateQueue")

    private var audioFile: AVAudioFile?
    private var lastNonSilentTime: Date?
    private var didNotifySilenceForCurrentPeriod = false
    private var silenceCheckTimer: DispatchSourceTimer?
    private var silenceCheckTickCount = 0
    private var lastNonSilentDiagnosticLogTime: Date = .distantPast
    private var lastRMSDiagnosticLogTime: Date = .distantPast
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
        let alreadyRunning = stateQueue.sync { isRunning }
        guard !alreadyRunning else {
            return
        }

        let permissionGranted = await requestMicrophonePermissionIfNeeded()
        guard permissionGranted else {
            throw MicCaptureError.microphonePermissionDenied
        }

        // Apply selected microphone device if configured
        if let selectedUID = UserDefaults.standard.string(forKey: "selectedMicrophoneUID"),
           !selectedUID.isEmpty {
            if let deviceID = audioDeviceID(forUID: selectedUID) {
                let inputAudioUnit = audioEngine.inputNode.audioUnit!
                var deviceIDVar = deviceID
                let status = AudioUnitSetProperty(
                    inputAudioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceIDVar,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    NSLog("MeetingRecorder: failed to set input device (status: \(status)), using default")
                }
            } else {
                NSLog("MeetingRecorder: stored microphone UID '\(selectedUID)' not found, falling back to default")
                UserDefaults.standard.removeObject(forKey: "selectedMicrophoneUID")
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw MicCaptureError.microphoneInputUnavailable
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        setAudioFile(file)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else {
                return
            }

            let rmsAmplitude = self.rmsAmplitude(for: buffer)
            var audioActivityCallbackToNotify: AudioActivityDetectedHandler?
            self.stateQueue.sync {
                guard self.isRunning else {
                    return
                }
                self.logRMSDiagnosticIfNeeded(rmsAmplitude: rmsAmplitude)
                let resumedFromSilence = self.updateSilenceTracking(rmsAmplitude: rmsAmplitude)
                if resumedFromSilence {
                    audioActivityCallbackToNotify = self.onAudioActivityDetectedHandler
                }
            }
            audioActivityCallbackToNotify?()

            self.fileLock.lock()
            defer { self.fileLock.unlock() }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                NSLog("MeetingRecorder: failed writing microphone buffer: \(error.localizedDescription)")
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            setAudioFile(nil)
            throw error
        }

        stateQueue.sync {
            self.isRunning = true
            self.lastNonSilentTime = Date()
            self.didNotifySilenceForCurrentPeriod = false
            self.silenceCheckTickCount = 0
            self.lastNonSilentDiagnosticLogTime = .distantPast
            self.lastRMSDiagnosticLogTime = .distantPast
        }
        startSilenceCheckTimer()
        let silenceDurationTrigger = stateQueue.sync { self.silenceDurationTrigger }
        NSLog(
            "MeetingRecorder: microphone silence detection armed (duration=\(silenceDurationTrigger)s, rmsThreshold=\(Self.silenceRMSThreshold))"
        )
    }

    func stop() {
        let wasRunning = stateQueue.sync { isRunning }
        guard wasRunning else {
            return
        }

        stopSilenceCheckTimer()
        stateQueue.sync {
            self.isRunning = false
            self.lastNonSilentTime = nil
            self.didNotifySilenceForCurrentPeriod = false
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        setAudioFile(nil)
    }

    private func updateSilenceTracking(rmsAmplitude: Float?) -> Bool {
        guard let rmsAmplitude else {
            return false
        }

        if rmsAmplitude >= Self.silenceRMSThreshold {
            let now = Date()
            let resumedFromSilence = didNotifySilenceForCurrentPeriod
            if now.timeIntervalSince(lastNonSilentDiagnosticLogTime) >= Self.nonSilentLogInterval {
                let dbFS = 20 * log10(max(Double(rmsAmplitude), 1e-9))
                NSLog(
                    "MeetingRecorder: non-silent microphone audio detected (rms=\(String(format: "%.5f", rmsAmplitude)), dbFS=\(String(format: "%.1f", dbFS)))"
                )
                lastNonSilentDiagnosticLogTime = now
            }
            lastNonSilentTime = now
            NSLog(
                "[SilenceDebug] MicCapture lastNonSilentTime reset from tap buffer: rms=%.5f threshold=%.5f",
                Double(rmsAmplitude),
                Double(Self.silenceRMSThreshold)
            )
            didNotifySilenceForCurrentPeriod = false
            if resumedFromSilence {
                NSLog("MeetingRecorder: microphone audio activity resumed after a silence period")
            }
            return resumedFromSilence
        }

        return false
    }

    private func startSilenceCheckTimer() {
        stateQueue.sync {
            _ = stopSilenceCheckTimerLocked()

            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            NSLog("[SilenceDebug] MicCapture silence timer created")
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.handleSilenceCheckTimerTickOnStateQueue()
            }
            silenceCheckTimer = timer
            silenceCheckTickCount = 0
            timer.resume()
            NSLog("[SilenceDebug] MicCapture silence timer resumed")
        }
        NSLog("MeetingRecorder: microphone silence check timer started")
    }

    private func stopSilenceCheckTimer() {
        let didStop = stateQueue.sync {
            stopSilenceCheckTimerLocked()
        }
        if didStop {
            NSLog("MeetingRecorder: microphone silence check timer stopped")
        }
    }

    private func stopSilenceCheckTimerLocked() -> Bool {
        guard let silenceCheckTimer else {
            return false
        }
        silenceCheckTimer.setEventHandler {}
        silenceCheckTimer.cancel()
        NSLog("[SilenceDebug] MicCapture silence timer cancelled")
        self.silenceCheckTimer = nil
        return true
    }

    private func handleSilenceCheckTimerTickOnStateQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))

        let now = Date()
        silenceCheckTickCount += 1

        guard isRunning else {
            NSLog("[SilenceDebug] MicCapture timer tick %d skipped: capture not running", silenceCheckTickCount)
            return
        }

        if lastNonSilentTime == nil {
            lastNonSilentTime = now
            NSLog("[SilenceDebug] MicCapture timer initialized lastNonSilentTime on tick %d", silenceCheckTickCount)
        }

        guard let lastNonSilentTime else {
            return
        }

        let elapsed = now.timeIntervalSince(lastNonSilentTime)
        let isSilent = elapsed >= silenceDurationTrigger
        NSLog(
            "[SilenceDebug] MicCapture timer tick: elapsed=%.1fs threshold=%.1fs state=%@ didNotify=%@ callbackNil=%@",
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
            "[SilenceDebug] MicCapture firing onSilenceDetected callback: elapsed=%.1fs callbackNil=%@",
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
                "[SilenceDebug] MicCapture tap RMS: unavailable threshold=%.5f",
                Double(Self.silenceRMSThreshold)
            )
            return
        }

        let classification = rmsAmplitude >= Self.silenceRMSThreshold ? "ABOVE_OR_EQUAL_THRESHOLD" : "BELOW_THRESHOLD"
        NSLog(
            "[SilenceDebug] MicCapture tap RMS: rms=%.5f threshold=%.5f classification=%@",
            Double(rmsAmplitude),
            Double(Self.silenceRMSThreshold),
            classification
        )
    }

    private func rmsAmplitude(for buffer: AVAudioPCMBuffer) -> Float? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            return nil
        }

        var sumSquares = 0.0
        var sampleTotalCount = 0

        if let floatChannelData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = floatChannelData[channel]
                for frame in 0..<frameLength {
                    let sample = Double(samples[frame])
                    sumSquares += sample * sample
                }
                sampleTotalCount += frameLength
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = int16ChannelData[channel]
                for frame in 0..<frameLength {
                    let normalizedSample = Double(samples[frame]) / Double(Int16.max)
                    sumSquares += normalizedSample * normalizedSample
                }
                sampleTotalCount += frameLength
            }
        } else if let int32ChannelData = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                let samples = int32ChannelData[channel]
                for frame in 0..<frameLength {
                    let normalizedSample = Double(samples[frame]) / Double(Int32.max)
                    sumSquares += normalizedSample * normalizedSample
                }
                sampleTotalCount += frameLength
            }
        } else {
            return nil
        }

        guard sampleTotalCount > 0 else {
            return nil
        }

        return Float(sqrt(sumSquares / Double(sampleTotalCount)))
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true

        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }

        case .denied, .restricted:
            return false

        @unknown default:
            return false
        }
    }

    private func setAudioFile(_ file: AVAudioFile?) {
        fileLock.lock()
        audioFile = file
        fileLock.unlock()
    }
}
