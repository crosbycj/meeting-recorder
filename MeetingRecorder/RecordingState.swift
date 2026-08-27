import Foundation

struct RecordingState: Sendable {
    let title: String?
    let attendees: [String]?
    let startTime: Date
    let associatedEventStartTime: Date?
    let associatedCalendarEventID: String?
    let recordingDirectoryURL: URL
    let systemAudioTempURL: URL
    let micAudioTempURL: URL
    let calendarEvent: Bool
    let isRecurring: Bool
    let systemAudioEnabled: Bool
    let micAudioEnabled: Bool

    var displayTitle: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? "Recording" : trimmedTitle
    }
}
