import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noAudioSourcesAvailable(systemError: Error?, micError: Error?)
    case metadataWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No active recording to stop."
        case .noAudioSourcesAvailable(let systemError, let micError):
            let systemMessage = systemError?.localizedDescription ?? "Unknown system audio error."
            let micMessage = micError?.localizedDescription ?? "Unknown microphone error."
            return "Could not start recording. System audio: \(systemMessage) Mic: \(micMessage)"
        case .metadataWriteFailed(let message):
            return "Recording finished but metadata could not be written: \(message)"
        }
    }
}

actor AudioRecorder {
    typealias RecordingStateChangeHandler = @MainActor @Sendable (RecordingState?) -> Void
    typealias SilenceDetectedHandler = @Sendable () -> Void

    private enum SilenceSource: String {
        case system
        case microphone
    }

    private struct SilenceAggregationState {
        var systemEnabled = false
        var microphoneEnabled = false
        var systemSilent = false
        var microphoneSilent = false
        var didNotifyCombinedSilence = false
    }

    private let storage: RecordingStorage
    private let mixer: AudioMixer
    private let fileManager: FileManager

    private var systemAudioCapture: SystemAudioCapture?
    private var micCapture: MicCapture?
    private var onRecordingStateChanged: RecordingStateChangeHandler?
    private var onSilenceDetected: SilenceDetectedHandler?
    private var silenceAggregationState = SilenceAggregationState()

    private var activeRecordingState: RecordingState? {
        didSet {
            notifyRecordingStateChanged(activeRecordingState)
        }
    }

    init(
        storage: RecordingStorage = RecordingStorage(),
        mixer: AudioMixer = AudioMixer(),
        fileManager: FileManager = .default
    ) {
        self.storage = storage
        self.mixer = mixer
        self.fileManager = fileManager
    }

    func setOnRecordingStateChanged(_ handler: RecordingStateChangeHandler?) {
        onRecordingStateChanged = handler
        notifyRecordingStateChanged(activeRecordingState)
    }

    func setOnSilenceDetected(_ handler: SilenceDetectedHandler?) {
        onSilenceDetected = handler
        NSLog(
            "[SilenceDebug] AudioRecorder MenuManager silence handler updated: nonNil=%@",
            handler == nil ? "NO" : "YES"
        )
    }

    func currentRecordingState() -> RecordingState? {
        activeRecordingState
    }

    func isRecording() -> Bool {
        activeRecordingState != nil
    }

    func reduceSilenceThresholds() {
        systemAudioCapture?.setSilenceDuration(10.0)
        micCapture?.setSilenceDuration(10.0)
    }

    func startRecording(
        eventTitle: String?,
        attendees: [String]?,
        startTime: Date,
        associatedEventStartTime: Date? = nil,
        associatedCalendarEventID: String? = nil,
        calendarEvent: Bool = false,
        isRecurring: Bool = false
    ) async throws {
        guard activeRecordingState == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        resetSilenceAggregationState()

        let recordingDirectoryURL = try await storage.createRecordingDirectory(eventTitle: eventTitle, startTime: startTime, isRecurring: isRecurring)
        let systemAudioTempURL = recordingDirectoryURL.appendingPathComponent("system-audio-temp.caf")
        let micAudioTempURL = recordingDirectoryURL.appendingPathComponent("mic-audio-temp.caf")

        let systemCapture = SystemAudioCapture(outputURL: systemAudioTempURL)
        let micCapture = MicCapture(outputURL: micAudioTempURL)
        self.systemAudioCapture = systemCapture
        self.micCapture = micCapture

        let systemCaptureID = Self.captureInstanceIdentifier(systemCapture)
        let micCaptureID = Self.captureInstanceIdentifier(micCapture)
        NSLog(
            "[SilenceDebug] AudioRecorder created capture instances: systemCaptureID=%@ micCaptureID=%@",
            systemCaptureID,
            micCaptureID
        )

        NSLog("[SilenceDebug] AudioRecorder wiring callbacks: setting SystemAudioCapture.onSilenceDetected")
        systemCapture.onSilenceDetected = { [weak self] in
            NSLog(
                "[SilenceDebug] AudioRecorder callback bridge invoked: source=system captureID=%@",
                systemCaptureID
            )
            NSLog("[SilenceDebug] AudioRecorder received silence callback from source=system")
            Task {
                await self?.handleSourceSilenceDetected(.system)
            }
        }
        NSLog(
            "[SilenceDebug] AudioRecorder wiring callbacks: SystemAudioCapture.onSilenceDetected nonNil=%@",
            systemCapture.onSilenceDetected == nil ? "NO" : "YES"
        )
        NSLog("[SilenceDebug] AudioRecorder wiring callbacks: setting SystemAudioCapture.onAudioActivityDetected")
        systemCapture.onAudioActivityDetected = { [weak self] in
            NSLog("[SilenceDebug] AudioRecorder received activity callback from source=system")
            Task {
                await self?.handleSourceAudioActivityDetected(.system)
            }
        }
        NSLog(
            "[SilenceDebug] AudioRecorder wiring callbacks: SystemAudioCapture.onAudioActivityDetected nonNil=%@",
            systemCapture.onAudioActivityDetected == nil ? "NO" : "YES"
        )
        NSLog("[SilenceDebug] AudioRecorder wiring callbacks: setting MicCapture.onSilenceDetected")
        micCapture.onSilenceDetected = { [weak self] in
            NSLog(
                "[SilenceDebug] AudioRecorder callback bridge invoked: source=microphone captureID=%@",
                micCaptureID
            )
            NSLog("[SilenceDebug] AudioRecorder received silence callback from source=microphone")
            Task {
                await self?.handleSourceSilenceDetected(.microphone)
            }
        }
        NSLog(
            "[SilenceDebug] AudioRecorder wiring callbacks: MicCapture.onSilenceDetected nonNil=%@",
            micCapture.onSilenceDetected == nil ? "NO" : "YES"
        )
        NSLog("[SilenceDebug] AudioRecorder wiring callbacks: setting MicCapture.onAudioActivityDetected")
        micCapture.onAudioActivityDetected = { [weak self] in
            NSLog("[SilenceDebug] AudioRecorder received activity callback from source=microphone")
            Task {
                await self?.handleSourceAudioActivityDetected(.microphone)
            }
        }
        NSLog(
            "[SilenceDebug] AudioRecorder wiring callbacks: MicCapture.onAudioActivityDetected nonNil=%@",
            micCapture.onAudioActivityDetected == nil ? "NO" : "YES"
        )

        var systemAudioEnabled = false
        var micAudioEnabled = false
        var systemError: Error?
        var micError: Error?

        do {
            try await systemCapture.start()
            systemAudioEnabled = true
            configureSilenceAggregationState(
                systemEnabled: systemAudioEnabled,
                microphoneEnabled: micAudioEnabled
            )
        } catch {
            systemError = error
            NSLog("MeetingRecorder: system audio capture unavailable: \(error.localizedDescription)")
        }

        do {
            try await micCapture.start()
            micAudioEnabled = true
            configureSilenceAggregationState(
                systemEnabled: systemAudioEnabled,
                microphoneEnabled: micAudioEnabled
            )
        } catch {
            micError = error
            NSLog("MeetingRecorder: microphone capture unavailable: \(error.localizedDescription)")
        }

        guard systemAudioEnabled || micAudioEnabled else {
            self.systemAudioCapture = nil
            self.micCapture = nil
            try? fileManager.removeItem(at: recordingDirectoryURL)
            throw AudioRecorderError.noAudioSourcesAvailable(systemError: systemError, micError: micError)
        }

        if !systemAudioEnabled {
            self.systemAudioCapture = nil
        } else {
            NSLog("MeetingRecorder: AudioRecorder retained SystemAudioCapture for active recording")
        }
        if !micAudioEnabled {
            self.micCapture = nil
        }

        configureSilenceAggregationState(
            systemEnabled: systemAudioEnabled,
            microphoneEnabled: micAudioEnabled
        )

        activeRecordingState = RecordingState(
            title: eventTitle,
            attendees: attendees,
            startTime: startTime,
            associatedEventStartTime: associatedEventStartTime,
            associatedCalendarEventID: associatedCalendarEventID,
            recordingDirectoryURL: recordingDirectoryURL,
            systemAudioTempURL: systemAudioTempURL,
            micAudioTempURL: micAudioTempURL,
            calendarEvent: calendarEvent,
            isRecurring: isRecurring,
            systemAudioEnabled: systemAudioEnabled,
            micAudioEnabled: micAudioEnabled
        )

        evaluateCombinedSilenceIfNeeded(triggeredBy: "recording-activated")
    }

    func stopRecording() async throws -> URL {
        guard let currentState = activeRecordingState else {
            throw AudioRecorderError.notRecording
        }

        let finalDirectoryURL = currentState.recordingDirectoryURL
        let outputAudioURL = finalDirectoryURL.appendingPathComponent("recording.m4a")
        let systemCapture = systemAudioCapture
        let micCapture = self.micCapture

        var mixSystemAudioURL: URL? = currentState.systemAudioEnabled ? currentState.systemAudioTempURL : nil
        let mixMicAudioURL: URL? = currentState.micAudioEnabled ? currentState.micAudioTempURL : nil

        defer {
            try? removeFileIfExists(at: currentState.systemAudioTempURL)
            try? removeFileIfExists(at: currentState.micAudioTempURL)
            cleanupState()
        }

        if let systemCapture {
            do {
                try await systemCapture.stop()
            } catch {
                NSLog("MeetingRecorder: failed to stop system audio capture: \(error.localizedDescription)")
                mixSystemAudioURL = nil
            }
        }

        if let micCapture {
            micCapture.stop()
        }

        _ = try await mixer.mix(
            systemAudioURL: mixSystemAudioURL,
            micAudioURL: mixMicAudioURL,
            outputURL: outputAudioURL
        )

        let duration = await Self.audioDuration(for: outputAudioURL)

        do {
            try await storage.writeMetadata(
                directoryURL: finalDirectoryURL,
                title: currentState.title,
                date: currentState.startTime,
                associatedEventStartTime: currentState.associatedEventStartTime,
                associatedCalendarEventID: currentState.associatedCalendarEventID,
                duration: duration,
                attendees: currentState.attendees,
                audioFileName: "recording.m4a",
                calendarEvent: currentState.calendarEvent,
                isRecurring: currentState.isRecurring
            )
        } catch {
            throw AudioRecorderError.metadataWriteFailed(error.localizedDescription)
        }

        return finalDirectoryURL
    }

    private func cleanupState() {
        systemAudioCapture = nil
        micCapture = nil
        resetSilenceAggregationState()
        activeRecordingState = nil
    }

    private func removeFileIfExists(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private static func audioDuration(for fileURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration), duration.isValid else {
            return 0
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            return 0
        }

        return seconds
    }

    private static func captureInstanceIdentifier(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }

    private func notifyRecordingStateChanged(_ state: RecordingState?) {
        guard let onRecordingStateChanged else {
            return
        }
        Task { @MainActor in
            onRecordingStateChanged(state)
        }
    }

    private func notifySilenceDetected() {
        guard let onSilenceDetected else {
            NSLog("[SilenceDebug] AudioRecorder combined silence decision: NOT firing MenuManager callback (handler is nil)")
            return
        }
        NSLog("[SilenceDebug] AudioRecorder combined silence decision: firing MenuManager callback")
        onSilenceDetected()
    }

    private func resetSilenceAggregationState() {
        silenceAggregationState = SilenceAggregationState()
        logSilenceAggregationState(context: "reset")
    }

    private func configureSilenceAggregationState(
        systemEnabled: Bool,
        microphoneEnabled: Bool
    ) {
        silenceAggregationState.systemEnabled = systemEnabled
        silenceAggregationState.microphoneEnabled = microphoneEnabled

        if !systemEnabled {
            silenceAggregationState.systemSilent = false
        }
        if !microphoneEnabled {
            silenceAggregationState.microphoneSilent = false
        }
        if !systemEnabled && !microphoneEnabled {
            silenceAggregationState.didNotifyCombinedSilence = false
        }

        logSilenceAggregationState(context: "configured")
    }

    private func handleSourceSilenceDetected(_ source: SilenceSource) {
        guard isSourceEnabled(source) else {
            NSLog("MeetingRecorder: ignoring \(source.rawValue) silence callback (source disabled)")
            return
        }

        setSourceSilent(source, silent: true)
        logSilenceAggregationState(context: "source=\(source.rawValue) reported silence")

        guard activeRecordingState != nil else {
            NSLog(
                "[SilenceDebug] AudioRecorder deferred combined silence evaluation (source=%@, no active recording state yet)",
                source.rawValue
            )
            return
        }

        evaluateCombinedSilenceIfNeeded(triggeredBy: source)
    }

    private func handleSourceAudioActivityDetected(_ source: SilenceSource) {
        guard isSourceEnabled(source) else {
            NSLog("MeetingRecorder: ignoring \(source.rawValue) activity callback (source disabled)")
            return
        }

        let wasSilent = isSourceSilent(source)
        setSourceSilent(source, silent: false)
        if wasSilent {
            silenceAggregationState.didNotifyCombinedSilence = false
            NSLog("[SilenceDebug] AudioRecorder source=%@ resumed activity; combined silence gate reset", source.rawValue)
        }
        logSilenceAggregationState(context: "source=\(source.rawValue) reported activity")

        guard activeRecordingState != nil else {
            NSLog(
                "[SilenceDebug] AudioRecorder recorded activity while recording state was not yet active (source=%@)",
                source.rawValue
            )
            return
        }
    }

    private func evaluateCombinedSilenceIfNeeded(triggeredBy source: SilenceSource) {
        evaluateCombinedSilenceIfNeeded(triggeredBy: source.rawValue)
    }

    private func evaluateCombinedSilenceIfNeeded(triggeredBy trigger: String) {
        let state = silenceAggregationState
        let hasAnyEnabledSource = state.systemEnabled || state.microphoneEnabled
        let allEnabledSourcesSilent = (!state.systemEnabled || state.systemSilent) &&
            (!state.microphoneEnabled || state.microphoneSilent)
        NSLog(
            "[SilenceDebug] AudioRecorder evaluating combined silence (trigger=%@): systemEnabled=%@ micEnabled=%@ systemSilent=%@ micSilent=%@ allSilent=%@ didNotify=%@",
            trigger,
            state.systemEnabled ? "YES" : "NO",
            state.microphoneEnabled ? "YES" : "NO",
            state.systemSilent ? "YES" : "NO",
            state.microphoneSilent ? "YES" : "NO",
            allEnabledSourcesSilent ? "YES" : "NO",
            state.didNotifyCombinedSilence ? "YES" : "NO"
        )
        guard hasAnyEnabledSource else {
            NSLog("[SilenceDebug] AudioRecorder combined silence decision: NOT firing (no enabled sources)")
            return
        }

        guard allEnabledSourcesSilent else {
            NSLog("[SilenceDebug] AudioRecorder combined silence decision: NOT firing (all-silent condition not met)")
            return
        }

        guard !state.didNotifyCombinedSilence else {
            NSLog("[SilenceDebug] AudioRecorder combined silence decision: NOT firing (already notified for current period)")
            return
        }

        silenceAggregationState.didNotifyCombinedSilence = true
        NSLog("[SilenceDebug] AudioRecorder combined silence decision: firing (all enabled sources silent)")
        notifySilenceDetected()
    }

    private func logSilenceAggregationState(context: String) {
        let state = silenceAggregationState
        let allEnabledSourcesSilent = (!state.systemEnabled || state.systemSilent) &&
            (!state.microphoneEnabled || state.microphoneSilent)
        NSLog(
            "[SilenceDebug] AudioRecorder aggregation state (%@): systemEnabled=%@ micEnabled=%@ systemSilent=%@ micSilent=%@ allSilent=%@ didNotify=%@",
            context,
            state.systemEnabled ? "YES" : "NO",
            state.microphoneEnabled ? "YES" : "NO",
            state.systemSilent ? "YES" : "NO",
            state.microphoneSilent ? "YES" : "NO",
            allEnabledSourcesSilent ? "YES" : "NO",
            state.didNotifyCombinedSilence ? "YES" : "NO"
        )
    }

    private func isSourceEnabled(_ source: SilenceSource) -> Bool {
        switch source {
        case .system:
            return silenceAggregationState.systemEnabled
        case .microphone:
            return silenceAggregationState.microphoneEnabled
        }
    }

    private func isSourceSilent(_ source: SilenceSource) -> Bool {
        switch source {
        case .system:
            return silenceAggregationState.systemSilent
        case .microphone:
            return silenceAggregationState.microphoneSilent
        }
    }

    private func setSourceSilent(_ source: SilenceSource, silent: Bool) {
        switch source {
        case .system:
            silenceAggregationState.systemSilent = silent
        case .microphone:
            silenceAggregationState.microphoneSilent = silent
        }
    }
}
