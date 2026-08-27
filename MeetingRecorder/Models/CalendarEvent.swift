import Foundation

struct CalendarEvent {
    let id: String
    let calendarID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let attendees: [String]?
    let meetingURL: URL?
    let isRecurring: Bool

    var attendeeCount: Int? {
        attendees?.count
    }
}
