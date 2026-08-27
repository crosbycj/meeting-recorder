import EventKit
import Foundation
import UserNotifications

enum MeetingReminderNotification {
    static let categoryIdentifier = "MEETING_REMINDER"
    static let openAndRecordActionIdentifier = "OPEN_AND_RECORD"
    static let requestIdentifierPrefix = "meeting-"

    private enum UserInfoKey {
        static let eventID = "eventID"
        static let title = "eventTitle"
        static let startDate = "eventStartDate"
        static let endDate = "eventEndDate"
        static let attendees = "eventAttendees"
        static let meetingURL = "eventMeetingURL"
        static let isRecurring = "eventIsRecurring"
    }

    struct EventContext {
        let eventID: String?
        let title: String
        let startDate: Date
        let endDate: Date?
        let attendees: [String]?
        let meetingURL: URL?
        let isRecurring: Bool
    }

    static func requestIdentifier(for event: CalendarEvent) -> String {
        let titleComponent = sanitizedIdentifierComponent(event.title)
        let startComponent = iso8601String(from: event.startDate)
            .replacingOccurrences(of: ":", with: "-")
        return "\(requestIdentifierPrefix)\(titleComponent)-\(startComponent)"
    }

    static func userInfo(for event: CalendarEvent) -> [String: Any] {
        var userInfo: [String: Any] = [
            UserInfoKey.eventID: event.id,
            UserInfoKey.title: event.title,
            UserInfoKey.startDate: iso8601String(from: event.startDate),
            UserInfoKey.endDate: iso8601String(from: event.endDate),
            UserInfoKey.attendees: event.attendees ?? []
        ]
        if let meetingURL = event.meetingURL?.absoluteString {
            userInfo[UserInfoKey.meetingURL] = meetingURL
        }
        userInfo[UserInfoKey.isRecurring] = event.isRecurring
        return userInfo
    }

    static func context(from userInfo: [AnyHashable: Any]) -> EventContext? {
        guard let title = userInfo[UserInfoKey.title] as? String,
              let startDateString = userInfo[UserInfoKey.startDate] as? String,
              let startDate = date(fromISO8601: startDateString) else {
            return nil
        }

        let eventID = userInfo[UserInfoKey.eventID] as? String
        let endDate = (userInfo[UserInfoKey.endDate] as? String).flatMap { date(fromISO8601: $0) }
        let attendees = userInfo[UserInfoKey.attendees] as? [String]
        let meetingURL = (userInfo[UserInfoKey.meetingURL] as? String).flatMap(URL.init(string:))
        let isRecurring = userInfo[UserInfoKey.isRecurring] as? Bool ?? false
        return EventContext(
            eventID: eventID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            attendees: attendees,
            meetingURL: meetingURL,
            isRecurring: isRecurring
        )
    }

    private static func sanitizedIdentifierComponent(_ rawValue: String) -> String {
        let sanitized = rawValue
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "untitled-event" : sanitized
    }

    private static func iso8601String(from date: Date) -> String {
        makeISO8601Formatter().string(from: date)
    }

    private static func date(fromISO8601 value: String) -> Date? {
        makeISO8601Formatter().date(from: value)
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

enum CalendarAuthorizationState {
    case notDetermined
    case authorized
    case denied
}

final class CalendarManager {
    private static let enabledCalendarIdentifiersDefaultsKey = "enabledCalendarIdentifiers"
    private static let meetingURLSearchExpressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"https://[\w.-]*zoom\.us/j/\d+(?:\?[^\s]*)?"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"https://meet\.google\.com/[a-z-]+"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"https://teams\.microsoft\.com/l/meetup-join/[^\s]+"#, options: [.caseInsensitive])
    ]
    private static let meetingURLExactExpressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^https://[\w.-]*zoom\.us/j/\d+(?:\?[^\s]*)?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^https://meet\.google\.com/[a-z-]+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^https://teams\.microsoft\.com/l/meetup-join/[^\s]+$"#, options: [.caseInsensitive])
    ]

    private let eventStore = EKEventStore()
    private let userDefaults: UserDefaults
    private var isRequestInFlight = false
    private var eventStoreChangedObserver: NSObjectProtocol?
    private var onEventsChanged: (() -> Void)?
    private var meetingReminderScheduleGeneration = 0

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    deinit {
        if let eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(eventStoreChangedObserver)
        }
    }

    var currentAuthorizationState: CalendarAuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .authorized
        case .writeOnly, .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAccessIfNeeded(completion: @escaping () -> Void) {
        switch currentAuthorizationState {
        case .authorized, .denied:
            completion()

        case .notDetermined:
            guard !isRequestInFlight else {
                return
            }

            isRequestInFlight = true
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.isRequestInFlight = false
                    completion()
                }
            }
        }
    }

    func setOnEventsChanged(_ handler: (() -> Void)?) {
        onEventsChanged = handler

        guard eventStoreChangedObserver == nil else {
            return
        }

        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileStoredEnabledCalendarIdentifiersIfNeeded()
            self?.refreshMeetingReminderNotifications()
            self?.onEventsChanged?()
        }
    }

    func availableEventCalendars() -> [EKCalendar] {
        guard currentAuthorizationState == .authorized else {
            return []
        }

        return eventStore.calendars(for: .event).sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func availableEventCalendarSourcesInStoreOrder() -> [EKSource] {
        guard currentAuthorizationState == .authorized else {
            return []
        }

        let eventCalendars = eventStore.calendars(for: .event)
        let sourceIdentifiers = Set(eventCalendars.map { $0.source.sourceIdentifier })
        return eventStore.sources.filter { sourceIdentifiers.contains($0.sourceIdentifier) }
    }

    func storedEnabledCalendarIdentifiers() -> Set<String>? {
        guard let rawIdentifiers = userDefaults.object(forKey: Self.enabledCalendarIdentifiersDefaultsKey) as? [String] else {
            return nil
        }
        return Set(rawIdentifiers)
    }

    func setEnabledCalendarIdentifiers(_ identifiers: Set<String>) {
        let sortedIdentifiers = Array(identifiers).sorted()
        userDefaults.set(sortedIdentifiers, forKey: Self.enabledCalendarIdentifiersDefaultsKey)
    }

    func refreshMeetingReminderNotifications() {
        _ = fetchTodaysEvents()
    }

    func fetchTodaysEvents(scheduleNotifications: Bool = true) -> [CalendarEvent] {
        let now = Date()

        guard currentAuthorizationState == .authorized else {
            if scheduleNotifications {
                scheduleMeetingReminderNotifications(for: [], referenceDate: now)
            }
            return []
        }

        let calendar = Calendar.current

        guard let dayInterval = calendar.dateInterval(of: .day, for: now) else {
            if scheduleNotifications {
                scheduleMeetingReminderNotifications(for: [], referenceDate: now)
            }
            return []
        }

        let availableCalendars = availableEventCalendars()
        let enabledCalendarIdentifiers = reconciledEnabledCalendarIdentifiers(for: availableCalendars)
        let calendarsToQuery: [EKCalendar]? = if let enabledCalendarIdentifiers {
            availableCalendars.filter { enabledCalendarIdentifiers.contains($0.calendarIdentifier) }
        } else {
            nil
        }

        let predicate = eventStore.predicateForEvents(
            withStart: dayInterval.start,
            end: dayInterval.end,
            calendars: calendarsToQuery
        )

        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let normalizedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = normalizedTitle.isEmpty ? "Untitled Event" : normalizedTitle
                let attendeeNames = event.attendees?
                    .compactMap { attendee -> String? in
                        let trimmedName = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmedName.isEmpty ? nil : trimmedName
                    }
                let isRecurring = isRecurringSeriesEvent(event)
                NSLog(
                    "MeetingRecorder: event recurrence classification title='%@' eventID='%@' hasRecurrenceRules=%@ hasOccurrenceDate=%@ isDetached=%@ isRecurring=%@",
                    title,
                    event.eventIdentifier ?? "nil",
                    event.hasRecurrenceRules ? "YES" : "NO",
                    event.occurrenceDate == nil ? "NO" : "YES",
                    event.isDetached ? "YES" : "NO",
                    isRecurring ? "YES" : "NO"
                )
                return CalendarEvent(
                    id: event.eventIdentifier ?? fallbackEventIdentifier(
                        calendarID: event.calendar.calendarIdentifier,
                        title: title,
                        startDate: event.startDate
                    ),
                    calendarID: event.calendar.calendarIdentifier,
                    title: title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    attendees: attendeeNames?.isEmpty == true ? nil : attendeeNames,
                    meetingURL: extractMeetingURL(from: event),
                    isRecurring: isRecurring
                )
            }

        if scheduleNotifications {
            scheduleMeetingReminderNotifications(for: events, referenceDate: now)
        }

        return events
    }

    func extractMeetingURL(from event: EKEvent) -> URL? {
        if let eventURL = event.url?.absoluteString,
           matchesMeetingURLExactly(eventURL),
           let url = URL(string: eventURL) {
            return url
        }

        if let location = event.location,
           let locationURL = firstMeetingURL(in: location) {
            return locationURL
        }

        if let notes = event.notes,
           let notesURL = firstMeetingURL(in: notes) {
            return notesURL
        }

        return nil
    }

    private func matchesMeetingURLExactly(_ value: String) -> Bool {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return Self.meetingURLExactExpressions.contains { expression in
            guard let match = expression.firstMatch(in: value, options: [], range: searchRange) else {
                return false
            }
            return NSEqualRanges(match.range, searchRange)
        }
    }

    private func firstMeetingURL(in text: String) -> URL? {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var earliestMatch: (location: Int, url: URL)?

        for expression in Self.meetingURLSearchExpressions {
            guard let match = expression.firstMatch(in: text, options: [], range: searchRange),
                  let range = Range(match.range, in: text) else {
                continue
            }
            let candidate = String(text[range])
            guard let url = URL(string: candidate) else {
                continue
            }
            if let currentMatch = earliestMatch, currentMatch.location <= match.range.location {
                continue
            }
            earliestMatch = (location: match.range.location, url: url)
        }

        return earliestMatch?.url
    }

    private func fallbackEventIdentifier(calendarID: String, title: String, startDate: Date) -> String {
        "\(calendarID)|\(Self.iso8601String(from: startDate))|\(title)"
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func isRecurringSeriesEvent(_ event: EKEvent) -> Bool {
        return event.hasRecurrenceRules || event.isDetached
    }

    private func scheduleMeetingReminderNotifications(for events: [CalendarEvent], referenceDate: Date) {
        let notificationRequests = meetingReminderRequests(for: events, referenceDate: referenceDate)
        let center = UNUserNotificationCenter.current()

        meetingReminderScheduleGeneration += 1
        let generation = meetingReminderScheduleGeneration

        center.getPendingNotificationRequests { [weak self] pendingRequests in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard generation == self.meetingReminderScheduleGeneration else {
                    return
                }

                let meetingRequestIDs = pendingRequests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(MeetingReminderNotification.requestIdentifierPrefix) }
                if !meetingRequestIDs.isEmpty {
                    center.removePendingNotificationRequests(withIdentifiers: meetingRequestIDs)
                }

                for request in notificationRequests {
                    center.add(request) { error in
                        if let error {
                            NSLog("MeetingRecorder: failed to schedule meeting reminder (\(request.identifier)): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func meetingReminderRequests(for events: [CalendarEvent], referenceDate: Date) -> [UNNotificationRequest] {
        let maxLeadTime: TimeInterval = 6 * 60 * 60

        return events.compactMap { event in
            let secondsUntilStart = event.startDate.timeIntervalSince(referenceDate)
            guard secondsUntilStart > 0,
                  secondsUntilStart <= maxLeadTime else {
                return nil
            }

            let content = UNMutableNotificationContent()
            content.title = "Meeting starting now"
            content.body = event.title
            content.categoryIdentifier = MeetingReminderNotification.categoryIdentifier
            content.sound = .default
            content.userInfo = MeetingReminderNotification.userInfo(for: event)

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilStart, repeats: false)
            let identifier = MeetingReminderNotification.requestIdentifier(for: event)
            return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }
    }

    private func reconcileStoredEnabledCalendarIdentifiersIfNeeded() {
        guard currentAuthorizationState == .authorized else {
            return
        }
        _ = reconciledEnabledCalendarIdentifiers(for: availableEventCalendars())
    }

    private func reconciledEnabledCalendarIdentifiers(for availableCalendars: [EKCalendar]) -> Set<String>? {
        guard let storedIdentifiers = storedEnabledCalendarIdentifiers() else {
            return nil
        }

        let availableCalendarIdentifiers = Set(availableCalendars.map(\.calendarIdentifier))
        let reconciledIdentifiers = storedIdentifiers.intersection(availableCalendarIdentifiers)
        if reconciledIdentifiers != storedIdentifiers {
            setEnabledCalendarIdentifiers(reconciledIdentifiers)
        }
        return reconciledIdentifiers
    }
}
