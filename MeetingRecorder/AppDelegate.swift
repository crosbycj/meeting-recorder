import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum TerminationStopResult {
        case completed(URL?)
        case timedOut
    }

    private let recordingStorage = RecordingStorage()
    private lazy var transcriptionManager = TranscriptionManager(recordingStorage: recordingStorage)
    private lazy var summaryManager = SummaryManager(recordingStorage: recordingStorage)
    @MainActor private lazy var menuManager = MenuManager(
        transcriptionManager: transcriptionManager,
        summaryManager: summaryManager,
        recordingStorage: recordingStorage
    )
    private var isTerminationInFlight = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureNotificationCenter()
        menuManager.configure()
        Task {
            await transcriptionManager.setSummaryManager(summaryManager)
            await transcriptionManager.preloadModel()
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationInFlight else {
            return .terminateLater
        }

        guard menuManager.isRecordingActive else {
            return .terminateNow
        }

        isTerminationInFlight = true
        let fallbackDirectoryURL = menuManager.activeRecordingDirectoryURL

        Task { [weak self] in
            guard let self else {
                return
            }

            let stoppedDirectoryURL = await self.stopRecordingForTerminationWithTimeout()
            let directoryURL = stoppedDirectoryURL ?? fallbackDirectoryURL
            if let directoryURL {
                await self.recordingStorage.updateTranscriptMetadata(
                    directoryURL: directoryURL,
                    status: "pending",
                    transcriptFile: nil
                )
            }

            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            self.isTerminationInFlight = false
        }

        return .terminateLater
    }

    @MainActor
    private func stopRecordingForTerminationWithTimeout() async -> URL? {
        await withTaskGroup(of: TerminationStopResult.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else {
                    return .completed(nil)
                }
                let directoryURL = await self.menuManager.stopRecordingForTermination()
                return .completed(directoryURL)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .timedOut
            }

            let firstResult = await group.next() ?? .completed(nil)
            group.cancelAll()

            switch firstResult {
            case .completed(let directoryURL):
                return directoryURL
            case .timedOut:
                NSLog("MeetingRecorder: termination stop timed out after 10 seconds")
                return nil
            }
        }
    }

    @MainActor
    private func configureNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let stopRecordingAction = UNNotificationAction(
            identifier: SilenceDetectionNotification.stopActionIdentifier,
            title: "Stop Recording",
            options: [.foreground]
        )
        let silenceCategory = UNNotificationCategory(
            identifier: SilenceDetectionNotification.categoryIdentifier,
            actions: [stopRecordingAction],
            intentIdentifiers: [],
            options: []
        )
        let openAndRecordAction = UNNotificationAction(
            identifier: MeetingReminderNotification.openAndRecordActionIdentifier,
            title: "Open Meeting & Record",
            options: [.foreground]
        )
        let meetingReminderCategory = UNNotificationCategory(
            identifier: MeetingReminderNotification.categoryIdentifier,
            actions: [openAndRecordAction],
            intentIdentifiers: [],
            options: []
        )
        let resumeRecordingAction = UNNotificationAction(
            identifier: MeetingEndNotification.resumeActionIdentifier,
            title: "Resume Recording",
            options: [.foreground]
        )
        let meetingEndedCategory = UNNotificationCategory(
            identifier: MeetingEndNotification.categoryIdentifier,
            actions: [resumeRecordingAction],
            intentIdentifiers: [],
            options: []
        )
        let startRecordingAction = UNNotificationAction(
            identifier: MeetingDetectedNotification.startRecordingActionIdentifier,
            title: "Start Recording",
            options: [.foreground]
        )
        let meetingDetectedCategory = UNNotificationCategory(
            identifier: MeetingDetectedNotification.categoryIdentifier,
            actions: [startRecordingAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([silenceCategory, meetingReminderCategory, meetingEndedCategory, meetingDetectedCategory])
        center.getNotificationCategories { categories in
            let hasSilenceCategory = categories.contains { $0.identifier == SilenceDetectionNotification.categoryIdentifier }
            let hasMeetingReminderCategory = categories.contains { $0.identifier == MeetingReminderNotification.categoryIdentifier }
            let hasMeetingEndedCategory = categories.contains { $0.identifier == MeetingEndNotification.categoryIdentifier }
            let hasMeetingDetectedCategory = categories.contains { $0.identifier == MeetingDetectedNotification.categoryIdentifier }
            NSLog(
                "[SilenceDebug] Notification categories registered: silence=%@ meetingReminder=%@ meetingEnded=%@ meetingDetected=%@",
                hasSilenceCategory ? "YES" : "NO",
                hasMeetingReminderCategory ? "YES" : "NO",
                hasMeetingEndedCategory ? "YES" : "NO",
                hasMeetingDetectedCategory ? "YES" : "NO"
            )
        }

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[SilenceDebug] Notification authorization request failed: %@", error.localizedDescription)
                return
            }
            NSLog(
                "[SilenceDebug] Notification authorization result at startup: %@",
                granted ? "granted" : "denied"
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer {
            completionHandler()
        }

        if response.notification.request.content.categoryIdentifier == MeetingReminderNotification.categoryIdentifier {
            Task { @MainActor [weak self] in
                self?.menuManager.markCalendarReminderNotificationDelivered()
            }
        }

        switch response.actionIdentifier {
        case SilenceDetectionNotification.stopActionIdentifier:
            Task { @MainActor [weak self] in
                self?.menuManager.stopRecordingFromNotificationAction()
            }
        case MeetingEndNotification.resumeActionIdentifier:
            Task { @MainActor [weak self] in
                self?.menuManager.startFreshRecording()
            }
        case MeetingReminderNotification.openAndRecordActionIdentifier:
            Task { @MainActor [weak self] in
                self?.handleMeetingReminderAction(userInfo: response.notification.request.content.userInfo)
            }
        case MeetingDetectedNotification.startRecordingActionIdentifier:
            Task { @MainActor [weak self] in
                self?.handleMeetingDetectedAction(userInfo: response.notification.request.content.userInfo)
            }
        case UNNotificationDefaultActionIdentifier:
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == MeetingReminderNotification.categoryIdentifier {
            Task { @MainActor [weak self] in
                self?.menuManager.markCalendarReminderNotificationDelivered()
            }
        }
        completionHandler([.banner, .list, .sound])
    }

    @MainActor
    private func handleMeetingReminderAction(userInfo: [AnyHashable: Any]) {
        guard let context = MeetingReminderNotification.context(from: userInfo) else {
            NSLog("MeetingRecorder: meeting reminder action ignored due to missing event context")
            return
        }
        menuManager.startRecordingFromMeetingReminder(context)
    }

    @MainActor
    private func handleMeetingDetectedAction(userInfo: [AnyHashable: Any]) {
        menuManager.startRecordingFromMeetingDetectedNotification(userInfo: userInfo)
    }
}
