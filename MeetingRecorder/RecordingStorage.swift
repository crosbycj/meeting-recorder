import EventKit
import Foundation

struct RecordingInfo: Sendable {
    let directoryURL: URL
    let meetingTitle: String?
    let generatedTitle: String?
    let date: Date
    let associatedEventStartTime: Date?
    let associatedCalendarEventID: String?
    let duration: TimeInterval
    let attendees: [String]
    let audioFileName: String
    let calendarEvent: Bool
    let hasTranscript: Bool
    let transcriptFileURL: URL?
    let transcriptionStatus: String?
    let summaryStatus: String?
    let summary: String?

    var audioFileURL: URL {
        directoryURL.appendingPathComponent(audioFileName)
    }

    var title: String {
        Self.resolvedTitle(meetingTitle: meetingTitle, generatedTitle: generatedTitle)
    }

    var isCollapsed: Bool {
        directoryURL.pathExtension == "txt"
    }

    var summaryPromptTitle: String? {
        if let meetingTitle = Self.normalizedOptionalTitle(from: meetingTitle) {
            return meetingTitle
        }
        if calendarEvent {
            return Self.normalizedOptionalTitle(from: generatedTitle)
        }
        return nil
    }

    private static func resolvedTitle(meetingTitle: String?, generatedTitle: String?) -> String {
        if let meetingTitle = normalizedOptionalTitle(from: meetingTitle) {
            return meetingTitle
        }
        if let generatedTitle = normalizedOptionalTitle(from: generatedTitle) {
            return generatedTitle
        }
        return "Recording"
    }

    private static func normalizedOptionalTitle(from title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

actor RecordingStorage {
    enum StorageError: LocalizedError {
        case metadataUnavailable(String)
        case transcriptWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .metadataUnavailable(let name):
                return "Failed to load metadata for \(name)."
            case .transcriptWriteFailed(let message):
                return "Failed to write transcript: \(message)"
            }
        }
    }

    private struct RecordingMetadata: Codable {
        var title: String?
        var meetingTitle: String?
        var generatedTitle: String?
        var date: String
        var associatedEventStartTime: String?
        var associatedCalendarEventID: String?
        var duration: TimeInterval
        var attendees: [String]
        var audioFile: String
        var calendarEvent: Bool
        var isRecurring: Bool
        var transcriptionStatus: String?
        var transcriptFile: String?
        var summaryStatus: String?
        var summaryFile: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            meetingTitle = try container.decodeIfPresent(String.self, forKey: .meetingTitle)
            generatedTitle = try container.decodeIfPresent(String.self, forKey: .generatedTitle)
            date = try container.decode(String.self, forKey: .date)
            associatedEventStartTime = try container.decodeIfPresent(String.self, forKey: .associatedEventStartTime)
            associatedCalendarEventID = try container.decodeIfPresent(String.self, forKey: .associatedCalendarEventID)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            attendees = try container.decode([String].self, forKey: .attendees)
            audioFile = try container.decode(String.self, forKey: .audioFile)
            calendarEvent = try container.decode(Bool.self, forKey: .calendarEvent)
            isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
            transcriptionStatus = try container.decodeIfPresent(String.self, forKey: .transcriptionStatus)
            transcriptFile = try container.decodeIfPresent(String.self, forKey: .transcriptFile)
            summaryStatus = try container.decodeIfPresent(String.self, forKey: .summaryStatus)
            summaryFile = try container.decodeIfPresent(String.self, forKey: .summaryFile)
        }

        init(
            title: String?,
            meetingTitle: String?,
            generatedTitle: String?,
            date: String,
            associatedEventStartTime: String?,
            associatedCalendarEventID: String?,
            duration: TimeInterval,
            attendees: [String],
            audioFile: String,
            calendarEvent: Bool,
            isRecurring: Bool,
            transcriptionStatus: String? = nil,
            transcriptFile: String? = nil,
            summaryStatus: String? = nil,
            summaryFile: String? = nil
        ) {
            self.title = title
            self.meetingTitle = meetingTitle
            self.generatedTitle = generatedTitle
            self.date = date
            self.associatedEventStartTime = associatedEventStartTime
            self.associatedCalendarEventID = associatedCalendarEventID
            self.duration = duration
            self.attendees = attendees
            self.audioFile = audioFile
            self.calendarEvent = calendarEvent
            self.isRecurring = isRecurring
            self.transcriptionStatus = transcriptionStatus
            self.transcriptFile = transcriptFile
            self.summaryStatus = summaryStatus
            self.summaryFile = summaryFile
        }
    }

    private let fileManager: FileManager
    private nonisolated let recordingsRootURL: URL
    private let datePrefixFormatter: DateFormatter
    private let timePrefixFormatter: DateFormatter
    private let metadataDateFormatter: ISO8601DateFormatter

    private static let otherRecordingsFolderName = "Other Recordings"

    private nonisolated var legacyRecordingsURL: URL {
        recordingsRootURL.appendingPathComponent("recordings", isDirectory: true)
    }

    private nonisolated var otherRecordingsURL: URL {
        recordingsRootURL.appendingPathComponent(Self.otherRecordingsFolderName, isDirectory: true)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        recordingsRootURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("MeetingRecorder", isDirectory: true)

        let prefixFormatter = DateFormatter()
        prefixFormatter.locale = .current
        prefixFormatter.calendar = .current
        prefixFormatter.dateFormat = "yyyy-MM-dd"
        datePrefixFormatter = prefixFormatter

        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.calendar = .current
        timeFormatter.dateFormat = "HHmm"
        timePrefixFormatter = timeFormatter

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        metadataDateFormatter = isoFormatter

        Self.migrateToV2IfNeeded(rootURL: recordingsRootURL, fileManager: fileManager)
        Self.collapseCompletedRecordingsIfNeeded(rootURL: recordingsRootURL, fileManager: fileManager)
    }

    func createRecordingDirectory(eventTitle: String?, startTime: Date, isRecurring: Bool = false) throws -> URL {
        try ensureRecordingsRootExists()

        if isRecurring, let title = normalizedOptionalTitle(from: eventTitle) {
            return try createRecurringSeriesDirectory(seriesTitle: title, startTime: startTime)
        }
        return try createOtherRecordingDirectory(eventTitle: eventTitle, startTime: startTime)
    }

    private func createRecurringSeriesDirectory(seriesTitle: String, startTime: Date) throws -> URL {
        let sanitizedTitle = Self.sanitizeForFilesystem(seriesTitle)
        let seriesURL = recordingsRootURL.appendingPathComponent(sanitizedTitle, isDirectory: true)
        let datePrefix = datePrefixFormatter.string(from: startTime)
        let baseName = datePrefix

        var directoryURL = seriesURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: directoryURL.path) {
            directoryURL = seriesURL.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func createOtherRecordingDirectory(eventTitle: String?, startTime: Date) throws -> URL {
        let datePrefix = datePrefixFormatter.string(from: startTime)
        let timePrefix = timePrefixFormatter.string(from: startTime)
        let baseSlug = slug(from: eventTitle)
        let baseName = "\(datePrefix)_\(timePrefix)_\(baseSlug)"

        var directoryURL = otherRecordingsURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: directoryURL.path) {
            directoryURL = otherRecordingsURL.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    func writeMetadata(
        directoryURL: URL,
        title: String?,
        date: Date,
        associatedEventStartTime: Date?,
        associatedCalendarEventID: String?,
        duration: TimeInterval,
        attendees: [String]?,
        audioFileName: String,
        calendarEvent: Bool,
        isRecurring: Bool = false
    ) throws {
        let normalizedMeetingTitle = normalizedOptionalTitle(from: title)
        let metadata = RecordingMetadata(
            title: normalizedTitle(from: title),
            meetingTitle: normalizedMeetingTitle,
            generatedTitle: nil,
            date: metadataDateFormatter.string(from: date),
            associatedEventStartTime: associatedEventStartTime.map { metadataDateFormatter.string(from: $0) },
            associatedCalendarEventID: associatedCalendarEventID,
            duration: duration,
            attendees: attendees ?? [],
            audioFile: audioFileName,
            calendarEvent: calendarEvent,
            isRecurring: isRecurring
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        try data.write(to: metadataURL, options: .atomic)
    }

    func applyGeneratedTitle(directoryURL: URL, generatedTitle: String?) -> URL {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard var metadata = loadMetadata(at: metadataURL) else {
            NSLog("MeetingRecorder: failed to read metadata for generated title update at \(directoryURL.lastPathComponent)")
            return directoryURL
        }

        guard let normalizedGeneratedTitle = normalizedOptionalTitle(from: generatedTitle) else {
            return directoryURL
        }

        metadata.generatedTitle = normalizedGeneratedTitle
        if normalizedOptionalTitle(from: metadata.meetingTitle) == nil {
            metadata.title = normalizedGeneratedTitle
        }

        guard writeMetadata(metadata, to: metadataURL) else {
            return directoryURL
        }

        updateTranscriptTitle(directoryURL: directoryURL, newTitle: normalizedGeneratedTitle)

        return renameDirectoryIfNeeded(directoryURL: directoryURL, metadata: metadata)
    }

    private func updateTranscriptTitle(directoryURL: URL, newTitle: String) {
        let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
        guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n")
        var updatedLines: [String] = []
        var replaced = false

        for line in lines {
            if !replaced, line.hasPrefix("Meeting: ") {
                updatedLines.append("Meeting: \(newTitle)")
                replaced = true
            } else {
                updatedLines.append(line)
            }
        }

        guard replaced else { return }

        let updatedContent = updatedLines.joined(separator: "\n")
        try? updatedContent.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    func renameDirectoryUsingStoredTitle(directoryURL: URL) -> URL {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard let metadata = loadMetadata(at: metadataURL) else {
            NSLog("MeetingRecorder: failed to read metadata for directory rename at \(directoryURL.lastPathComponent)")
            return directoryURL
        }

        return renameDirectoryIfNeeded(directoryURL: directoryURL, metadata: metadata)
    }

    func listRecentRecordings(days: Int = 7, referenceDate: Date = Date()) -> [RecordingInfo] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: referenceDate)
        guard let cutoffDate = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: startOfToday) else {
            return []
        }

        return listAllRecordings()
            .filter { calendar.startOfDay(for: $0.date) >= cutoffDate }
            .sorted { $0.date > $1.date }
    }

    func listAllRecordings() -> [RecordingInfo] {
        Self.recordingDirectoryURLs(at: recordingsRootURL, fileManager: fileManager)
            .compactMap { recordingInfo(for: $0) }
            .sorted { $0.date > $1.date }
    }

    func recordingInfo(for directoryURL: URL) -> RecordingInfo? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue, directoryURL.pathExtension == "txt" {
            return recordingInfoFromCollapsedFile(at: directoryURL)
        }

        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        guard
            let data = try? Data(contentsOf: metadataURL),
            let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data),
            let date = metadataDateFormatter.date(from: metadata.date)
        else {
            return nil
        }

        let hasTranscript = metadata.transcriptionStatus == "completed"
        let transcriptFileURL: URL? = metadata.transcriptFile.map {
            directoryURL.appendingPathComponent($0)
        }
        let associatedEventStartTime = metadata.associatedEventStartTime.flatMap {
            metadataDateFormatter.date(from: $0)
        }

        var summary: String?
        if metadata.summaryStatus == "completed", let summaryFileName = metadata.summaryFile {
            let summaryURL = directoryURL.appendingPathComponent(summaryFileName)
            summary = try? String(contentsOf: summaryURL, encoding: .utf8)
        }

        return RecordingInfo(
            directoryURL: directoryURL,
            meetingTitle: metadata.meetingTitle,
            generatedTitle: metadata.generatedTitle ?? normalizedOptionalTitle(from: metadata.title),
            date: date,
            associatedEventStartTime: associatedEventStartTime,
            associatedCalendarEventID: metadata.associatedCalendarEventID,
            duration: metadata.duration,
            attendees: metadata.attendees,
            audioFileName: metadata.audioFile,
            calendarEvent: metadata.calendarEvent,
            hasTranscript: hasTranscript,
            transcriptFileURL: hasTranscript ? transcriptFileURL : nil,
            transcriptionStatus: metadata.transcriptionStatus,
            summaryStatus: metadata.summaryStatus,
            summary: summary
        )
    }

    func updateTranscriptMetadata(directoryURL: URL, status: String, transcriptFile: String?) {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else {
            NSLog("MeetingRecorder: failed to read metadata for transcript update at \(directoryURL.lastPathComponent)")
            return
        }

        metadata.transcriptionStatus = status
        metadata.transcriptFile = transcriptFile

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let updatedData = try encoder.encode(metadata)
            try updatedData.write(to: metadataURL, options: .atomic)
        } catch {
            NSLog("MeetingRecorder: failed to update transcript metadata: \(error.localizedDescription)")
        }
    }

    func saveTranscriptFile(directoryURL: URL, transcriptionResult: TranscriptionResult) throws {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data),
              let date = metadataDateFormatter.date(from: metadata.date) else {
            throw StorageError.metadataUnavailable(directoryURL.lastPathComponent)
        }

        var lines: [String] = []

        lines.append("Meeting: \(resolvedTitle(from: metadata))")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        lines.append("Date: \(dateFormatter.string(from: date))")

        lines.append("Duration: \(formattedHumanDuration(metadata.duration))")

        if !metadata.attendees.isEmpty {
            lines.append("Attendees: \(metadata.attendees.joined(separator: ", "))")
        }

        lines.append("")
        lines.append(transcriptionResult.text)

        let content = lines.joined(separator: "\n")
        let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
        do {
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw StorageError.transcriptWriteFailed(error.localizedDescription)
        }
    }

    func updateSummaryMetadata(directoryURL: URL, status: String, summaryFile: String?) {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard var metadata = loadMetadata(at: metadataURL) else {
            NSLog("MeetingRecorder: failed to read metadata for summary update at \(directoryURL.lastPathComponent)")
            return
        }

        metadata.summaryStatus = status
        metadata.summaryFile = summaryFile

        _ = writeMetadata(metadata, to: metadataURL)
    }

    func saveSummaryFile(directoryURL: URL, summary: String) throws {
        let summaryURL = directoryURL.appendingPathComponent("summary.txt")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    func updateTranscriptWithSummary(directoryURL: URL, summary: String) throws {
        let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
        let content = try String(contentsOf: transcriptURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        var updatedLines: [String] = []
        var insertedSummary = false

        for line in lines {
            if !insertedSummary && line.trimmingCharacters(in: .whitespaces).isEmpty {
                updatedLines.append("Summary: \(summary)")
                insertedSummary = true
            }
            updatedLines.append(line)
        }

        let updatedContent = updatedLines.joined(separator: "\n")
        try updatedContent.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Collapsed Recording Parsing

    private func recordingInfoFromCollapsedFile(at fileURL: URL) -> RecordingInfo? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")

        var meetingTitle: String?
        var dateString: String?
        var durationString: String?
        var attendeesString: String?
        var summaryText: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }

            if trimmed.hasPrefix("Meeting: ") {
                meetingTitle = String(trimmed.dropFirst("Meeting: ".count))
            } else if trimmed.hasPrefix("Date: ") {
                dateString = String(trimmed.dropFirst("Date: ".count))
            } else if trimmed.hasPrefix("Duration: ") {
                durationString = String(trimmed.dropFirst("Duration: ".count))
            } else if trimmed.hasPrefix("Attendees: ") {
                attendeesString = String(trimmed.dropFirst("Attendees: ".count))
            } else if trimmed.hasPrefix("Summary: ") {
                summaryText = String(trimmed.dropFirst("Summary: ".count))
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let parsedDate = dateString.flatMap { dateFormatter.date(from: $0) }
            ?? Self.fallbackDateFromFilename(fileURL)

        guard let date = parsedDate else { return nil }

        let duration = Self.parseDurationString(durationString)

        let attendees = attendeesString?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        return RecordingInfo(
            directoryURL: fileURL,
            meetingTitle: meetingTitle,
            generatedTitle: nil,
            date: date,
            associatedEventStartTime: nil,
            associatedCalendarEventID: nil,
            duration: duration,
            attendees: attendees,
            audioFileName: "",
            calendarEvent: false,
            hasTranscript: true,
            transcriptFileURL: fileURL,
            transcriptionStatus: "completed",
            summaryStatus: summaryText != nil ? "completed" : nil,
            summary: summaryText
        )
    }

    private nonisolated static func fallbackDateFromFilename(_ fileURL: URL) -> Date? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let fullFormatter = DateFormatter()
        fullFormatter.locale = Locale(identifier: "en_US_POSIX")
        fullFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        if name.count >= 15, let date = fullFormatter.date(from: String(name.prefix(15))) {
            return date
        }
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if name.count >= 10, let date = dateOnlyFormatter.date(from: String(name.prefix(10))) {
            return date
        }
        return nil
    }

    private nonisolated static func parseDurationString(_ durationString: String?) -> TimeInterval {
        guard let str = durationString else { return 0 }
        if str == "less than a minute" { return 30 }
        var totalSeconds = 0
        let hourPattern = try! NSRegularExpression(pattern: #"(\d+)\s+hours?"#)
        if let match = hourPattern.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
           let range = Range(match.range(at: 1), in: str) {
            totalSeconds += (Int(str[range]) ?? 0) * 3600
        }
        let minutePattern = try! NSRegularExpression(pattern: #"(\d+)\s+minutes?"#)
        if let match = minutePattern.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
           let range = Range(match.range(at: 1), in: str) {
            totalSeconds += (Int(str[range]) ?? 0) * 60
        }
        return TimeInterval(totalSeconds)
    }

    // MARK: - Recording Collapse

    func collapseCompletedRecording(directoryURL: URL) -> URL? {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard let metadata = loadMetadata(at: metadataURL) else {
            NSLog("MeetingRecorder: collapse skipped — no metadata at \(directoryURL.lastPathComponent)")
            return nil
        }

        guard metadata.transcriptionStatus == "completed",
              metadata.summaryStatus == "completed" else {
            return nil
        }

        let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            NSLog("MeetingRecorder: collapse skipped — no transcript.txt in \(directoryURL.lastPathComponent)")
            return nil
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        let baseName = directoryURL.lastPathComponent
        var destinationURL = parentURL.appendingPathComponent("\(baseName).txt")

        var suffix = 2
        while fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = parentURL.appendingPathComponent("\(baseName)-\(suffix).txt")
            suffix += 1
        }

        do {
            try fileManager.copyItem(at: transcriptURL, to: destinationURL)
        } catch {
            NSLog("MeetingRecorder: collapse failed — could not copy transcript: \(error.localizedDescription)")
            return nil
        }

        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            NSLog("MeetingRecorder: collapse warning — copied transcript but failed to remove directory: \(error.localizedDescription)")
        }

        NSLog("MeetingRecorder: collapsed \(directoryURL.lastPathComponent) -> \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    nonisolated var rootURL: URL {
        recordingsRootURL
    }

    func ensureRootDirectoryExists() throws {
        try ensureRecordingsRootExists()
    }

    private func formattedHumanDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(max(0, duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 && minutes > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(hours) \(hourWord) \(minutes) \(minuteWord)"
        } else if hours > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            return "\(hours) \(hourWord)"
        } else if minutes > 0 {
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(minutes) \(minuteWord)"
        } else {
            return "less than a minute"
        }
    }

    private func ensureRecordingsRootExists() throws {
        try fileManager.createDirectory(at: recordingsRootURL, withIntermediateDirectories: true)
    }

    private nonisolated static func migrateToV2IfNeeded(rootURL: URL, fileManager: FileManager) {
        let migrationKey = "storageV2Migrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        let legacyURL = rootURL.appendingPathComponent("recordings", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        NSLog("MeetingRecorder: starting storage v2 migration")

        // Collect recurring event titles from EventKit for the past 90 days
        var recurringTitles = Set<String>()
        let eventStore = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let calendar = Calendar.current
            let now = Date()
            if let startDate = calendar.date(byAdding: .day, value: -90, to: now) {
                let predicate = eventStore.predicateForEvents(withStart: startDate, end: now, calendars: nil)
                let events = eventStore.events(matching: predicate)
                for event in events {
                    if event.hasRecurrenceRules {
                        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !title.isEmpty {
                            recurringTitles.insert(title)
                        }
                    }
                }
            }
            NSLog("MeetingRecorder: migration found %d recurring event titles", recurringTitles.count)
        } else {
            NSLog("MeetingRecorder: migration has no calendar access, all recordings go to Other Recordings")
        }

        let otherURL = rootURL.appendingPathComponent(otherRecordingsFolderName, isDirectory: true)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.calendar = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        guard let entries = try? fileManager.contentsOfDirectory(
            at: legacyURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }

            let metadataURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else {
                // No metadata — move to Other Recordings as-is
                moveForMigration(entry, into: otherURL, name: entry.lastPathComponent, fileManager: fileManager)
                continue
            }

            let meetingTitle = (metadata.meetingTitle ?? metadata.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleKey = meetingTitle.lowercased()

            if !titleKey.isEmpty, recurringTitles.contains(titleKey) {
                // Recurring: move into series folder with date-only name
                let seriesName = sanitizeForFilesystem(meetingTitle)
                let seriesURL = rootURL.appendingPathComponent(seriesName, isDirectory: true)
                let dateName: String
                if let date = isoFormatter.date(from: metadata.date) {
                    dateName = dateFormatter.string(from: date)
                } else {
                    dateName = entry.lastPathComponent
                }
                moveForMigration(entry, into: seriesURL, name: dateName, fileManager: fileManager)
            } else {
                // Non-recurring: move to Other Recordings keeping original folder name
                moveForMigration(entry, into: otherURL, name: entry.lastPathComponent, fileManager: fileManager)
            }
        }

        // Remove empty legacy directory
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyURL.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyURL)
            NSLog("MeetingRecorder: removed empty legacy recordings directory")
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        NSLog("MeetingRecorder: storage v2 migration complete")
    }

    private nonisolated static func moveForMigration(
        _ sourceURL: URL,
        into parentURL: URL,
        name: String,
        fileManager: FileManager
    ) {
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            NSLog("MeetingRecorder: migration failed to create directory %@: %@", parentURL.path, error.localizedDescription)
            return
        }

        var destinationURL = parentURL.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = parentURL.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            NSLog("MeetingRecorder: migrated %@ -> %@", sourceURL.lastPathComponent, destinationURL.path)
        } catch {
            NSLog("MeetingRecorder: migration failed to move %@: %@", sourceURL.lastPathComponent, error.localizedDescription)
        }
    }

    private nonisolated static func collapseCompletedRecordingsIfNeeded(rootURL: URL, fileManager: FileManager) {
        let migrationKey = "storageV3CollapseMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        NSLog("MeetingRecorder: starting v3 collapse migration")

        let directories = recordingDirectoryURLs(at: rootURL, fileManager: fileManager)
        var collapsedCount = 0

        for directoryURL in directories {
            let metadataURL = directoryURL.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else {
                continue
            }

            guard metadata.transcriptionStatus == "completed",
                  metadata.summaryStatus == "completed" else {
                continue
            }

            let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
            guard fileManager.fileExists(atPath: transcriptURL.path) else {
                continue
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            let baseName = directoryURL.lastPathComponent
            var destinationURL = parentURL.appendingPathComponent("\(baseName).txt")

            var suffix = 2
            while fileManager.fileExists(atPath: destinationURL.path) {
                destinationURL = parentURL.appendingPathComponent("\(baseName)-\(suffix).txt")
                suffix += 1
            }

            do {
                try fileManager.copyItem(at: transcriptURL, to: destinationURL)
                try fileManager.removeItem(at: directoryURL)
                collapsedCount += 1
                NSLog("MeetingRecorder: migration collapsed %@ -> %@", directoryURL.lastPathComponent, destinationURL.lastPathComponent)
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                NSLog("MeetingRecorder: migration failed to collapse %@: %@", directoryURL.lastPathComponent, error.localizedDescription)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        NSLog("MeetingRecorder: v3 collapse migration complete (collapsed %d recording(s))", collapsedCount)
    }

    private func renameDirectoryIfNeeded(directoryURL: URL, metadata: RecordingMetadata) -> URL {
        guard let recordingDate = metadataDateFormatter.date(from: metadata.date) else {
            return directoryURL
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        let isInSeriesFolder = parentURL.standardizedFileURL != recordingsRootURL.standardizedFileURL
            && parentURL.lastPathComponent != Self.otherRecordingsFolderName

        let baseName: String
        if isInSeriesFolder {
            baseName = datePrefixFormatter.string(from: recordingDate)
        } else {
            let datePrefix = datePrefixFormatter.string(from: recordingDate)
            let timePrefix = timePrefixFormatter.string(from: recordingDate)
            let titleSlug = slug(from: resolvedTitle(from: metadata))
            baseName = "\(datePrefix)_\(timePrefix)_\(titleSlug)"
        }

        var candidateURL = parentURL.appendingPathComponent(baseName, isDirectory: true)
        let sourceURL = directoryURL.standardizedFileURL
        var suffix = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            if candidateURL.standardizedFileURL == sourceURL {
                return directoryURL
            }
            candidateURL = parentURL.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: directoryURL, to: candidateURL)
            return candidateURL
        } catch {
            NSLog("MeetingRecorder: failed to rename recording folder \(directoryURL.lastPathComponent): \(error.localizedDescription)")
            return directoryURL
        }
    }

    private func loadMetadata(at metadataURL: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(RecordingMetadata.self, from: data)
    }

    @discardableResult
    private func writeMetadata(_ metadata: RecordingMetadata, to metadataURL: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let updatedData = try encoder.encode(metadata)
            try updatedData.write(to: metadataURL, options: .atomic)
            return true
        } catch {
            NSLog("MeetingRecorder: failed to write metadata: \(error.localizedDescription)")
            return false
        }
    }

    private func slug(from title: String?) -> String {
        let normalized = normalizedTitle(from: title)
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if normalized.isEmpty {
            return "recording"
        }

        let maxLength = 40
        if normalized.count <= maxLength {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<endIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func sanitizeForFilesystem(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "[/:\\x00-\\x1f]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let maxLength = 60
        if cleaned.count > maxLength {
            let endIndex = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
            cleaned = String(cleaned[..<endIndex]).trimmingCharacters(in: .whitespaces)
        }

        cleaned = cleaned
            .replacingOccurrences(of: "^\\.+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "Untitled"
        }

        if cleaned.caseInsensitiveCompare(otherRecordingsFolderName) == .orderedSame {
            cleaned += " (Series)"
        }

        return cleaned
    }

    nonisolated static func recordingDirectoryURLs(at rootURL: URL, fileManager: FileManager = .default) -> [URL] {
        guard let topLevelEntries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var locations: [URL] = []
        for entry in topLevelEntries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if values?.isDirectory == true {
                let childLocations = childRecordingLocationURLs(in: entry, fileManager: fileManager)
                let hasMetadata = fileManager.fileExists(atPath: entry.appendingPathComponent("metadata.json").path)

                if hasMetadata, childLocations.isEmpty {
                    locations.append(entry)
                } else {
                    locations.append(contentsOf: childLocations)
                }
            } else if values?.isRegularFile == true, entry.pathExtension == "txt" {
                locations.append(entry)
            }
        }

        return locations
    }

    private nonisolated static func childRecordingLocationURLs(in parentURL: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var childLocations: [URL] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if values?.isDirectory == true {
                if fileManager.fileExists(atPath: child.appendingPathComponent("metadata.json").path) {
                    childLocations.append(child)
                }
            } else if values?.isRegularFile == true, child.pathExtension == "txt" {
                childLocations.append(child)
            }
        }

        return childLocations
    }

    private func normalizedTitle(from title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? "Recording" : trimmedTitle
    }

    private func normalizedOptionalTitle(from title: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    private func resolvedTitle(from metadata: RecordingMetadata) -> String {
        if let meetingTitle = normalizedOptionalTitle(from: metadata.meetingTitle) {
            return meetingTitle
        }
        if let generatedTitle = normalizedOptionalTitle(from: metadata.generatedTitle) {
            return generatedTitle
        }
        if let legacyTitle = normalizedOptionalTitle(from: metadata.title) {
            return legacyTitle
        }
        return "Recording"
    }
}
