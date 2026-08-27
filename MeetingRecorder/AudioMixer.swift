@preconcurrency import AVFoundation
import Foundation

enum AudioMixerError: LocalizedError {
    case noAudioSourcesAvailable
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioSourcesAvailable:
            return "No audio was captured from either system audio or microphone."
        case .exportSessionUnavailable:
            return "Failed to create audio export session."
        case .exportFailed(let message):
            return "Audio export failed: \(message)"
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }
}

final class AudioMixer {
    typealias ProgressHandler = (Double) -> Void

    func mix(
        systemAudioURL: URL?,
        micAudioURL: URL?,
        outputURL: URL,
        progressHandler: ProgressHandler? = nil
    ) async throws -> URL {
        let candidateURLs = [systemAudioURL, micAudioURL].compactMap { $0 }
        let validURLs = candidateURLs.filter { Self.fileHasAudioData(at: $0) }
        guard !validURLs.isEmpty else {
            throw AudioMixerError.noAudioSourcesAvailable
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        var insertedTrack = false

        for inputURL in validURLs {
            let asset = AVURLAsset(url: inputURL)
            guard
                let sourceTracks = try? await asset.loadTracks(withMediaType: .audio),
                let sourceTrack = sourceTracks.first
            else {
                continue
            }

            guard let duration = try? await asset.load(.duration) else {
                continue
            }
            guard duration.isValid, duration.seconds > 0 else {
                continue
            }

            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
            insertedTrack = true
        }

        guard insertedTrack else {
            throw AudioMixerError.noAudioSourcesAvailable
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioMixerError.exportSessionUnavailable
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false
        let sessionBox = ExportSessionBox(session: exportSession)

        let progressTask = Task {
            while !Task.isCancelled {
                progressHandler?(Double(sessionBox.session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        defer {
            progressTask.cancel()
        }

        try await withCheckedThrowingContinuation { continuation in
            sessionBox.session.exportAsynchronously {
                switch sessionBox.session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(
                        throwing: AudioMixerError.exportFailed(
                            sessionBox.session.error?.localizedDescription ?? "Unknown export failure."
                        )
                    )
                case .cancelled:
                    continuation.resume(throwing: AudioMixerError.exportFailed("Export was cancelled."))
                default:
                    continuation.resume(
                        throwing: AudioMixerError.exportFailed(
                            "Export ended with status \(sessionBox.session.status.rawValue)."
                        )
                    )
                }
            }
        }

        progressHandler?(1.0)
        return outputURL
    }

    private static func fileHasAudioData(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return false
        }

        return fileSize.intValue > 0
    }
}
