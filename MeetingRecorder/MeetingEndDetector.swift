import Foundation

@MainActor
protocol MeetingEndDetectorDelegate: AnyObject {
    func meetingEndDetectorDidDetectMeetingEnded(_ detector: MeetingEndDetector)
    func meetingEndDetectorDidPassCalendarEndTime(_ detector: MeetingEndDetector)
}

@MainActor
final class MeetingEndDetector {
    weak var delegate: MeetingEndDetectorDelegate?

    var isMonitoring: Bool {
        pollingTimer != nil
    }

    private static let pollingInterval: TimeInterval = 2.0
    private static let minimumMonitoringDurationBeforeAutoStop: TimeInterval = 20.0
    private static let requiredNoSignalDurationForMeetingEnd: TimeInterval = 12.0
    private static let minimumSignalDurationToArmAutoStop: TimeInterval = 30.0

    private let signalProviders: [MeetingSignalProvider]

    private var pollingTimer: Timer?
    private var hasObservedMeetingSignal = false
    private var meetingSignalObservedSince: Date?
    private var noSignalSince: Date?
    private var monitoringStartDate: Date?
    private var monitoringCalendarEventEndDate: Date?
    private var monitoringCalendarEventID: String?
    private var lastPollTimestamp: Date?
    private var hasReportedCalendarEndTimePassage = false

    convenience init() {
        self.init(signalProviders: [
            ZoomProcessSignalProvider(),
            WindowTitleSignalProvider()
        ])
    }

    init(signalProviders: [MeetingSignalProvider]) {
        self.signalProviders = signalProviders
    }

    func startMonitoring(calendarEventEndDate: Date?, calendarEventID: String?) {
        stopMonitoring()

        monitoringCalendarEventEndDate = calendarEventEndDate
        monitoringCalendarEventID = calendarEventID

        let now = Date()
        let isMeetingDetectedAtStart = isMeetingDetectedByAnyProvider()
        hasObservedMeetingSignal = false
        meetingSignalObservedSince = isMeetingDetectedAtStart ? now : nil
        noSignalSince = isMeetingDetectedAtStart ? nil : now
        monitoringStartDate = now
        lastPollTimestamp = now
        if let calendarEventEndDate {
            hasReportedCalendarEndTimePassage = now >= calendarEventEndDate
        } else {
            hasReportedCalendarEndTimePassage = false
        }

        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSignals()
            }
        }
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil

        hasObservedMeetingSignal = false
        meetingSignalObservedSince = nil
        noSignalSince = nil
        monitoringStartDate = nil
        monitoringCalendarEventEndDate = nil
        monitoringCalendarEventID = nil
        lastPollTimestamp = nil
        hasReportedCalendarEndTimePassage = false
    }

    private func pollSignals() {
        guard isMonitoring else {
            return
        }

        let now = Date()
        let isMeetingDetectedNow = isMeetingDetectedByAnyProvider()
        if isMeetingDetectedNow {
            if meetingSignalObservedSince == nil {
                meetingSignalObservedSince = now
            }
            if !hasObservedMeetingSignal,
               let meetingSignalObservedSince,
               now.timeIntervalSince(meetingSignalObservedSince) >= Self.minimumSignalDurationToArmAutoStop {
                hasObservedMeetingSignal = true
                NSLog(
                    "MeetingRecorder: [MeetingEndDetector] auto-stop armed after %.1fs of sustained meeting signals",
                    now.timeIntervalSince(meetingSignalObservedSince)
                )
            }
            noSignalSince = nil
        } else {
            meetingSignalObservedSince = nil
            if noSignalSince == nil {
                noSignalSince = now
            }
        }

        let monitoringElapsed = now.timeIntervalSince(monitoringStartDate ?? now)
        let hasPassedMonitoringWarmup = monitoringElapsed >= Self.minimumMonitoringDurationBeforeAutoStop
        let noSignalDuration = now.timeIntervalSince(noSignalSince ?? now)
        let hasSustainedNoSignal = noSignalDuration >= Self.requiredNoSignalDurationForMeetingEnd
        let shouldReportMeetingEnded = hasObservedMeetingSignal &&
            hasPassedMonitoringWarmup &&
            hasSustainedNoSignal

        var shouldReportCalendarEndPassage = false
        if let calendarEventEndDate = monitoringCalendarEventEndDate,
           !hasReportedCalendarEndTimePassage {
            let previousTimestamp = lastPollTimestamp ?? now
            if previousTimestamp < calendarEventEndDate, now >= calendarEventEndDate {
                hasReportedCalendarEndTimePassage = true
                shouldReportCalendarEndPassage = true
            } else if now >= calendarEventEndDate {
                hasReportedCalendarEndTimePassage = true
            }
        }

        lastPollTimestamp = now

        if shouldReportMeetingEnded {
            NSLog(
                "MeetingRecorder: [MeetingEndDetector] Meeting end detected — no active meeting signals for %.1fs after %.1fs monitoring",
                noSignalDuration,
                monitoringElapsed
            )
            delegate?.meetingEndDetectorDidDetectMeetingEnded(self)
        }

        if shouldReportCalendarEndPassage, isMonitoring {
            delegate?.meetingEndDetectorDidPassCalendarEndTime(self)
        }
    }

    private func isMeetingDetectedByAnyProvider() -> Bool {
        signalProviders.contains { $0.isMeetingActive() }
    }
}
