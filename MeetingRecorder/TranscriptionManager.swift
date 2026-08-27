import Foundation
import FluidAudio

enum TranscriptionState: Sendable {
    case idle
    case downloadingModel(progress: Double)
    case loadingModel
    case ready
    case transcribing(directoryURL: URL, progress: Double)
    case error(String)
}

actor TranscriptionManager {
    typealias StateChangeHandler = @MainActor @Sendable (TranscriptionState) -> Void

    private let recordingStorage: RecordingStorage
    private var asrManager: AsrManager?
    private var models: AsrModels?
    private var ctcModels: CtcModels?
    private var ctcTokenizer: CtcTokenizer?
    private var queuedDirectoryURLs: [URL] = []
    private var progressObservationTask: Task<Void, Never>?
    private var modelDownloadProgressTask: Task<Void, Never>?
    private var isDrainingQueue = false
    private var didRunStartupReconciliation = false
    private var onStateChanged: StateChangeHandler?
    private var summaryManager: SummaryManager?

    init(recordingStorage: RecordingStorage = RecordingStorage()) {
        self.recordingStorage = recordingStorage
    }

    func setSummaryManager(_ manager: SummaryManager) {
        summaryManager = manager
    }

    private var state: TranscriptionState = .idle {
        didSet {
            notifyStateChanged(state)
        }
    }

    func setOnStateChanged(_ handler: StateChangeHandler?) {
        onStateChanged = handler
        notifyStateChanged(state)
    }

    func preloadModel() async {
        switch state {
        case .ready, .downloadingModel, .loadingModel, .transcribing:
            return
        case .idle, .error:
            break
        }

        let loaded = await downloadAndLoadModel()
        if loaded {
            await runStartupReconciliationIfNeeded()
            await drainQueueIfNeeded()
        }
    }

    func transcribe(directoryURL: URL) async {
        switch state {
        case .ready:
            _ = await enqueueForTranscription(directoryURL)
            await drainQueueIfNeeded()
        case .idle:
            _ = await enqueueForTranscription(directoryURL)
            let loaded = await downloadAndLoadModel()
            if loaded {
                await runStartupReconciliationIfNeeded()
                await drainQueueIfNeeded()
            }
        case .downloadingModel, .loadingModel, .transcribing:
            _ = await enqueueForTranscription(directoryURL)
        case .error:
            _ = await enqueueForTranscription(directoryURL)
            let recovered = await retryModelLoadOnceAfterFailure()
            if recovered {
                await drainQueueIfNeeded()
            }
        }
    }

    private func enqueueForTranscription(_ directoryURL: URL) async -> Bool {
        if queuedDirectoryURLs.contains(directoryURL) {
            return false
        }
        if case .transcribing(let activeDirectoryURL, _) = state, activeDirectoryURL == directoryURL {
            return false
        }

        queuedDirectoryURLs.append(directoryURL)
        await recordingStorage.updateTranscriptMetadata(
            directoryURL: directoryURL,
            status: "pending",
            transcriptFile: nil
        )
        NSLog("MeetingRecorder: queued transcription for \(directoryURL.lastPathComponent)")
        return true
    }

    private func downloadAndLoadModel() async -> Bool {
        if case .ready = state {
            return true
        }
        if case .downloadingModel = state {
            return false
        }
        if case .loadingModel = state {
            return false
        }

        let initialProgress = modelDownloadProgress()
        state = .downloadingModel(progress: initialProgress)
        startModelDownloadProgressPolling()
        NSLog("MeetingRecorder: downloading transcription model...")

        do {
            let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)
            stopModelDownloadProgressPolling()
            state = .loadingModel
            NSLog("MeetingRecorder: loading transcription model...")

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: downloadedModels)

            asrManager = manager
            models = downloadedModels
            state = .ready
            NSLog("MeetingRecorder: transcription model ready")
            return true
        } catch {
            stopModelDownloadProgressPolling()
            NSLog("MeetingRecorder: failed to load transcription model: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            return false
        }
    }

    func deleteModelCache() throws {
        progressObservationTask?.cancel()
        progressObservationTask = nil
        stopModelDownloadProgressPolling()

        asrManager = nil
        models = nil

        let fileManager = FileManager.default
        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        if fileManager.fileExists(atPath: modelCacheDirectory.path) {
            try fileManager.removeItem(at: modelCacheDirectory)
            NSLog("MeetingRecorder: deleted transcription model cache at \(modelCacheDirectory.path)")
        }

        state = .idle
    }

    private func retryModelLoadOnceAfterFailure() async -> Bool {
        guard case .error = state else {
            return false
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return await downloadAndLoadModel()
    }

    private func runStartupReconciliationIfNeeded() async {
        guard !didRunStartupReconciliation else {
            return
        }
        didRunStartupReconciliation = true

        let allRecordings = await recordingStorage.listAllRecordings()
        guard !allRecordings.isEmpty else {
            NSLog("MeetingRecorder: startup reconciliation found no recordings to inspect")
            return
        }

        var recoveredTranscriptionCount = 0
        var recoveredSummaryCount = 0

        for recording in allRecordings {
            let transcriptionStatus = recording.transcriptionStatus ?? ""
            if transcriptionStatus == "pending" || transcriptionStatus == "transcribing" {
                let audioFileURL = recording.directoryURL.appendingPathComponent("recording.m4a")
                guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
                    NSLog("MeetingRecorder: skipping transcription recovery for \(recording.directoryURL.lastPathComponent) (missing recording.m4a)")
                    continue
                }

                if await enqueueForTranscription(recording.directoryURL) {
                    recoveredTranscriptionCount += 1
                    NSLog("MeetingRecorder: recovered transcription job for \(recording.directoryURL.lastPathComponent)")
                }
                continue
            }

            guard transcriptionStatus == "completed" else {
                continue
            }

            guard let summaryStatus = recording.summaryStatus, summaryStatus == "pending" || summaryStatus == "generating" else {
                continue
            }

            if await enqueueSummaryGenerationForRecoveredRecording(recording) {
                recoveredSummaryCount += 1
                NSLog("MeetingRecorder: recovered summary job for \(recording.directoryURL.lastPathComponent)")
            }
        }

        NSLog(
            "MeetingRecorder: startup reconciliation complete (recovered \(recoveredTranscriptionCount) transcription job(s), \(recoveredSummaryCount) summary job(s))"
        )
    }

    private func enqueueSummaryGenerationForRecoveredRecording(_ recording: RecordingInfo) async -> Bool {
        guard let summaryManager else {
            NSLog("MeetingRecorder: cannot recover summary for \(recording.directoryURL.lastPathComponent) because SummaryManager is unavailable")
            return false
        }
        guard let transcriptURL = recording.transcriptFileURL else {
            NSLog("MeetingRecorder: cannot recover summary for \(recording.directoryURL.lastPathComponent) because transcript file is missing")
            return false
        }
        guard let transcriptContent = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            NSLog("MeetingRecorder: cannot recover summary for \(recording.directoryURL.lastPathComponent) because transcript file could not be read")
            return false
        }

        let extractedTranscriptBody = transcriptBody(from: transcriptContent)
        let transcriptForSummary = extractedTranscriptBody.isEmpty ? transcriptContent : extractedTranscriptBody
        let meetingTitle = recording.summaryPromptTitle

        Task {
            await summaryManager.generateSummary(
                directoryURL: recording.directoryURL,
                transcript: transcriptForSummary,
                meetingTitle: meetingTitle,
                attendees: recording.attendees
            )
        }
        return true
    }

    private func drainQueueIfNeeded() async {
        guard case .ready = state else {
            return
        }
        guard !isDrainingQueue else {
            return
        }

        isDrainingQueue = true
        defer {
            isDrainingQueue = false
        }

        while case .ready = state, !queuedDirectoryURLs.isEmpty {
            let directoryURL = queuedDirectoryURLs.removeFirst()
            await beginTranscription(directoryURL: directoryURL)
        }
    }

    private func beginTranscription(directoryURL: URL) async {
        guard let asrManager else {
            NSLog("MeetingRecorder: asrManager not available")
            state = .error("ASR manager unavailable")
            return
        }

        progressObservationTask?.cancel()
        progressObservationTask = nil

        state = .transcribing(directoryURL: directoryURL, progress: 0)
        await recordingStorage.updateTranscriptMetadata(
            directoryURL: directoryURL,
            status: "transcribing",
            transcriptFile: nil
        )

        let audioFileURL = directoryURL.appendingPathComponent("recording.m4a")
        let recordingInfo = await recordingStorage.recordingInfo(for: directoryURL)
        let attendees = recordingInfo?.attendees
        NSLog("MeetingRecorder: starting transcription of \(directoryURL.lastPathComponent)")

        progressObservationTask = Task { [weak self] in
            guard let self else {
                return
            }

            let progressStream = await asrManager.transcriptionProgressStream
            do {
                for try await progress in progressStream {
                    await self.updateProgress(directoryURL: directoryURL, progress: progress)
                }
            } catch {
                // Ignore progress stream termination errors.
            }
        }

        defer {
            progressObservationTask?.cancel()
            progressObservationTask = nil
        }

        do {
            await configureVocabularyBoostingIfPossible(asrManager: asrManager, attendees: attendees)
            defer {
                asrManager.disableVocabularyBoosting()
            }

            let asrResult = try await asrManager.transcribe(audioFileURL, source: .system)
            if let detectedTerms = asrResult.ctcDetectedTerms, !detectedTerms.isEmpty {
                NSLog("MeetingRecorder: CTC detected name terms for \(directoryURL.lastPathComponent): \(detectedTerms.joined(separator: ", "))")
            }
            if let appliedTerms = asrResult.ctcAppliedTerms, !appliedTerms.isEmpty {
                NSLog("MeetingRecorder: CTC applied name terms for \(directoryURL.lastPathComponent): \(appliedTerms.joined(separator: ", "))")
            }

            let words: [TranscriptionResult.WordTiming]? = asrResult.tokenTimings?.map { timing in
                TranscriptionResult.WordTiming(
                    word: timing.token,
                    startTime: timing.startTime,
                    endTime: timing.endTime
                )
            }

            let result = TranscriptionResult(
                text: asrResult.text,
                words: words,
                confidence: Double(asrResult.confidence),
                audioDuration: asrResult.duration,
                processingTime: asrResult.processingTime
            )

            do {
                try await recordingStorage.saveTranscriptFile(directoryURL: directoryURL, transcriptionResult: result)
                await recordingStorage.updateTranscriptMetadata(
                    directoryURL: directoryURL,
                    status: "completed",
                    transcriptFile: "transcript.txt"
                )

                NSLog("MeetingRecorder: transcription completed for \(directoryURL.lastPathComponent) in \(String(format: "%.1f", result.processingTime))s")

                if let summaryManager {
                    let summaryContext = await recordingStorage.recordingInfo(for: directoryURL)
                    let meetingTitle = summaryContext?.summaryPromptTitle
                    let summaryAttendees = summaryContext?.attendees
                    let transcript = result.text
                    Task {
                        await summaryManager.generateSummary(
                            directoryURL: directoryURL,
                            transcript: transcript,
                            meetingTitle: meetingTitle,
                            attendees: summaryAttendees
                        )
                    }
                }
            } catch {
                NSLog("MeetingRecorder: transcript save failed for \(directoryURL.lastPathComponent): \(error.localizedDescription)")
                await recordingStorage.updateTranscriptMetadata(
                    directoryURL: directoryURL,
                    status: "failed",
                    transcriptFile: nil
                )
            }
        } catch {
            NSLog("MeetingRecorder: transcription failed for \(directoryURL.lastPathComponent): \(error.localizedDescription)")
            await recordingStorage.updateTranscriptMetadata(
                directoryURL: directoryURL,
                status: "failed",
                transcriptFile: nil
            )
        }

        state = .ready
    }

    private func updateProgress(directoryURL: URL, progress: Double) {
        guard case .transcribing(let currentURL, _) = state, currentURL == directoryURL else {
            return
        }
        state = .transcribing(directoryURL: currentURL, progress: progress)
    }

    private func startModelDownloadProgressPolling() {
        stopModelDownloadProgressPolling()

        modelDownloadProgressTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let progress = await self.modelDownloadProgress()
                await self.updateModelDownloadProgress(progress)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopModelDownloadProgressPolling() {
        modelDownloadProgressTask?.cancel()
        modelDownloadProgressTask = nil
    }

    private func updateModelDownloadProgress(_ progress: Double) {
        guard case .downloadingModel(let currentProgress) = state else {
            return
        }

        let clampedProgress = max(0.0, min(progress, 1.0))
        guard abs(clampedProgress - currentProgress) >= 0.0001 else {
            return
        }

        state = .downloadingModel(progress: clampedProgress)
    }

    private func modelDownloadProgress() -> Double {
        let requiredModels = AsrModels.requiredModelNames
        guard !requiredModels.isEmpty else {
            return 0.0
        }

        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        let downloadedModelCount = requiredModels.reduce(0) { count, modelName in
            let modelURL = modelCacheDirectory.appendingPathComponent(modelName, isDirectory: true)
            return FileManager.default.fileExists(atPath: modelURL.path) ? count + 1 : count
        }

        return Double(downloadedModelCount) / Double(requiredModels.count)
    }

    private func transcriptBody(from transcriptContent: String) -> String {
        guard let firstSeparatorRange = transcriptContent.range(of: "\n\n") else {
            return transcriptContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(transcriptContent[firstSeparatorRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureVocabularyBoostingIfPossible(asrManager: AsrManager, attendees: [String]?) async {
        let resolvedParticipants = ParticipantNameResolver.resolve(attendees: attendees)
        guard !resolvedParticipants.participants.isEmpty else {
            return
        }

        do {
            let (ctcModels, ctcTokenizer) = try await loadCtcResources()
            guard let vocabulary = buildVocabularyContext(
                from: resolvedParticipants,
                tokenizer: ctcTokenizer
            ) else {
                return
            }

            try await asrManager.configureVocabularyBoosting(
                vocabulary: vocabulary,
                ctcModels: ctcModels
            )
            NSLog("MeetingRecorder: enabled attendee name biasing with \(vocabulary.terms.count) term(s)")
        } catch {
            NSLog("MeetingRecorder: attendee name biasing unavailable (\(error.localizedDescription)); continuing without biasing")
        }
    }

    private func loadCtcResources() async throws -> (CtcModels, CtcTokenizer) {
        if let ctcModels, let ctcTokenizer {
            return (ctcModels, ctcTokenizer)
        }

        let downloadedModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: downloadedModels.variant)
        )
        ctcModels = downloadedModels
        ctcTokenizer = tokenizer
        return (downloadedModels, tokenizer)
    }

    private func buildVocabularyContext(
        from resolvedParticipants: ResolvedParticipants,
        tokenizer: CtcTokenizer
    ) -> CustomVocabularyContext? {
        let terms: [CustomVocabularyTerm] = resolvedParticipants.participants.compactMap { participant in
            let tokenIds = tokenizer.encode(participant.canonicalName)
            guard !tokenIds.isEmpty else {
                return nil
            }

            return CustomVocabularyTerm(
                text: participant.canonicalName,
                weight: 10.0,
                aliases: participant.aliases.isEmpty ? nil : participant.aliases,
                tokenIds: nil,
                ctcTokenIds: tokenIds
            )
        }

        guard !terms.isEmpty else {
            return nil
        }
        return CustomVocabularyContext(terms: terms)
    }

    private func notifyStateChanged(_ state: TranscriptionState) {
        guard let onStateChanged else {
            return
        }
        Task { @MainActor in
            onStateChanged(state)
        }
    }
}
