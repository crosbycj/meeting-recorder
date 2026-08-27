import Foundation
import Security
import Cocoa

enum SummaryState: Sendable {
    case idle
    case generating(directoryURL: URL)
    case completed(directoryURL: URL)
    case error(String)
    case noApiKey
}

actor SummaryManager {
    typealias StateChangeHandler = @MainActor @Sendable (SummaryState) -> Void

    private struct SummaryResponse {
        let generatedTitle: String?
        let summary: String
    }

    private struct ClaudeSummaryPayload: Decodable {
        let title: String?
        let summary: String?
    }

    private var onStateChanged: StateChangeHandler?
    private let recordingStorage: RecordingStorage
    private var cachedApiKey: String?

    private var state: SummaryState {
        didSet {
            notifyStateChanged(state)
        }
    }

    private static let keychainService = "MeetingRecorder (Anthropic API Key)"
    private static let keychainAccount = "anthropic-api-key"

    init(recordingStorage: RecordingStorage = RecordingStorage()) {
        self.recordingStorage = recordingStorage
        let key = SummaryManager.retrieveApiKeySync()
        cachedApiKey = key
        state = key != nil ? .idle : .noApiKey
    }

    func setOnStateChanged(_ handler: StateChangeHandler?) {
        onStateChanged = handler
        notifyStateChanged(state)
    }

    // MARK: - Keychain

    private static func retrieveApiKeySync() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func retrieveApiKey() -> String? {
        cachedApiKey
    }

    func storeApiKey(_ key: String) -> Bool {
        deleteApiKey()

        guard let data = key.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SummaryManager.keychainService,
            kSecAttrAccount as String: SummaryManager.keychainAccount,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            cachedApiKey = key
        }
        return status == errSecSuccess
    }

    func deleteApiKey() {
        cachedApiKey = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SummaryManager.keychainService,
            kSecAttrAccount as String: SummaryManager.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    func setApiKey(_ key: String) -> Bool {
        let stored = storeApiKey(key)
        if stored {
            state = .idle
        }
        return stored
    }

    @MainActor
    static func promptForApiKey() -> String? {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Enter your Anthropic API key to enable meeting summaries. Get one at console.anthropic.com\n\nYour key is stored securely in the macOS Keychain. You may see a system prompt asking to allow Meeting Recorder to access it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "sk-ant-..."
        textField.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.lineBreakMode = .byClipping
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Summary Generation

    func generateSummary(directoryURL: URL, transcript: String, meetingTitle: String?, attendees: [String]?) async {
        var workingDirectoryURL = directoryURL
        guard let apiKey = retrieveApiKey() else {
            state = .noApiKey
            await recordingStorage.updateSummaryMetadata(directoryURL: workingDirectoryURL, status: "no_api_key", summaryFile: nil)
            return
        }

        state = .generating(directoryURL: workingDirectoryURL)
        await recordingStorage.updateSummaryMetadata(directoryURL: workingDirectoryURL, status: "generating", summaryFile: nil)

        do {
            let summaryResponse = try await callClaudeAPI(
                apiKey: apiKey,
                transcript: transcript,
                meetingTitle: meetingTitle,
                attendees: attendees
            )

            let hasMeetingTitle = !(meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if !hasMeetingTitle, let generatedTitle = summaryResponse.generatedTitle {
                workingDirectoryURL = await recordingStorage.applyGeneratedTitle(
                    directoryURL: workingDirectoryURL,
                    generatedTitle: generatedTitle
                )
            }

            try await recordingStorage.saveSummaryFile(directoryURL: workingDirectoryURL, summary: summaryResponse.summary)
            await recordingStorage.updateSummaryMetadata(directoryURL: workingDirectoryURL, status: "completed", summaryFile: "summary.txt")

            do {
                try await recordingStorage.updateTranscriptWithSummary(directoryURL: workingDirectoryURL, summary: summaryResponse.summary)
            } catch {
                NSLog("MeetingRecorder: failed to update transcript with summary: \(error.localizedDescription)")
            }

            state = .completed(directoryURL: workingDirectoryURL)
            NSLog("MeetingRecorder: summary generated for \(workingDirectoryURL.lastPathComponent)")
        } catch {
            NSLog("MeetingRecorder: summary generation failed for \(workingDirectoryURL.lastPathComponent): \(error.localizedDescription)")
            if case .noApiKey = state {
                await recordingStorage.updateSummaryMetadata(directoryURL: workingDirectoryURL, status: "no_api_key", summaryFile: nil)
            } else {
                await recordingStorage.updateSummaryMetadata(directoryURL: workingDirectoryURL, status: "failed", summaryFile: nil)
                state = .error(error.localizedDescription)
            }
        }
    }

    private func callClaudeAPI(
        apiKey: String,
        transcript: String,
        meetingTitle: String?,
        attendees: [String]?
    ) async throws -> SummaryResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let truncatedTranscript: String
        if transcript.count > 80_000 {
            let startIndex = transcript.index(transcript.startIndex, offsetBy: 40_000)
            let endIndex = transcript.index(transcript.endIndex, offsetBy: -40_000)
            truncatedTranscript = String(transcript[..<startIndex]) + "\n\n[transcript truncated]\n\n" + String(transcript[endIndex...])
        } else {
            truncatedTranscript = transcript
        }

        let resolvedAttendees = ParticipantNameResolver.resolve(attendees: attendees).canonicalNames
        let systemPrompt = """
        You are a meeting assistant.
        Return valid JSON only, with this exact schema:
        {"title":"...","summary":"..."}
        Rules:
        - title must be 2-6 words and sound like a meeting name.
        - title must NOT start with "Meeting about" or "Discussion of".
        - summary must be 1-2 sentences, specific and concise.
        - If attendee names are provided, prefer those exact spellings for people when context matches.
        - Do not include markdown, code fences, or any extra keys/text.
        """
        let trimmedMeetingTitle = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var promptSections: [String] = []
        if !trimmedMeetingTitle.isEmpty {
            promptSections.append("Meeting title: \(trimmedMeetingTitle)")
        }
        if !resolvedAttendees.isEmpty {
            promptSections.append("Known attendee names: \(resolvedAttendees.joined(separator: ", "))")
        }
        promptSections.append("Transcript:\n\(truncatedTranscript)")
        let userContent = promptSections.joined(separator: "\n\n")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 220,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userContent]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            deleteApiKey()
            state = .noApiKey
            throw SummaryError.unauthorized
        case 429:
            throw SummaryError.rateLimited
        case 500...:
            throw SummaryError.serverError(httpResponse.statusCode)
        default:
            throw SummaryError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw SummaryError.parseError
        }

        return parseSummaryResponse(from: text)
    }

    private func parseSummaryResponse(from responseText: String) -> SummaryResponse {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            return SummaryResponse(generatedTitle: nil, summary: "")
        }

        if let payload = decodeSummaryPayload(from: trimmedResponse) {
            let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty {
                let generatedTitle = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return SummaryResponse(
                    generatedTitle: generatedTitle?.isEmpty == true ? nil : generatedTitle,
                    summary: summary
                )
            }
        }

        // Fallback: if the model emits plain text, treat it as the summary and skip generated title.
        return SummaryResponse(generatedTitle: nil, summary: trimmedResponse)
    }

    private func decodeSummaryPayload(from rawText: String) -> ClaudeSummaryPayload? {
        if let payload = decodeSummaryPayloadJSON(rawText) {
            return payload
        }

        if rawText.hasPrefix("```"), rawText.hasSuffix("```") {
            let unfenced = rawText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let payload = decodeSummaryPayloadJSON(unfenced) {
                return payload
            }
        }

        guard let firstBrace = rawText.firstIndex(of: "{"),
              let lastBrace = rawText.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }

        let candidate = String(rawText[firstBrace ... lastBrace])
        return decodeSummaryPayloadJSON(candidate)
    }

    private func decodeSummaryPayloadJSON(_ text: String) -> ClaudeSummaryPayload? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeSummaryPayload.self, from: data)
    }

    private func notifyStateChanged(_ state: SummaryState) {
        guard let onStateChanged else {
            return
        }
        Task { @MainActor in
            onStateChanged(state)
        }
    }
}

enum SummaryError: LocalizedError {
    case unauthorized
    case rateLimited
    case serverError(Int)
    case httpError(Int)
    case invalidResponse
    case parseError

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid API key (401). Key has been removed."
        case .rateLimited:
            return "Rate limited by Anthropic API (429). Try again later."
        case .serverError(let code):
            return "Anthropic API server error (\(code))."
        case .httpError(let code):
            return "Anthropic API error (\(code))."
        case .invalidResponse:
            return "Invalid response from Anthropic API."
        case .parseError:
            return "Failed to parse Anthropic API response."
        }
    }
}
