import AVFoundation
import Cocoa
import CoreGraphics
import EventKit
import FluidAudio
import ServiceManagement
import UserNotifications

enum SilenceDetectionNotification {
    static let categoryIdentifier = "SILENCE_DETECTED"
    static let stopActionIdentifier = "STOP_RECORDING"
    static let requestIdentifier = "silence-detection"
}

@MainActor
final class MenuManager: NSObject, NSMenuDelegate, NSWindowDelegate {
    private enum MenuDateFormatting {
        private static let posixLocale = Locale(identifier: "en_US_POSIX")
        private static let calendar = Calendar.current

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = posixLocale
            formatter.calendar = calendar
            formatter.dateFormat = "h:mm a"
            return formatter
        }()

        private static let monthDayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = posixLocale
            formatter.calendar = calendar
            formatter.dateFormat = "MMM d"
            return formatter
        }()

        private static let monthDayYearFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = posixLocale
            formatter.calendar = calendar
            formatter.dateFormat = "MMM d, yyyy"
            return formatter
        }()

        static func menuTimeString(from date: Date) -> String {
            timeFormatter.string(from: date).lowercased()
        }

        static func menuDateString(from date: Date, referenceDate: Date = Date()) -> String {
            if calendar.isDate(date, equalTo: referenceDate, toGranularity: .year) {
                return monthDayFormatter.string(from: date)
            }
            return monthDayYearFormatter.string(from: date)
        }

        static func recordingRowTitle(date: Date, title: String, referenceDate: Date = Date()) -> String {
            let prefix = if calendar.isDateInToday(date) {
                menuTimeString(from: date)
            } else {
                menuDateString(from: date, referenceDate: referenceDate)
            }
            return "\(prefix) – \(title)"
        }

        static func eventRowTitle(startDate: Date, title: String) -> String {
            "\(menuTimeString(from: startDate)) – \(title)"
        }
    }

    private final class RecordingSummaryMenuItemView: NSView {
        private let summaryLabel: NSTextField
        private let preferredTextWidth: CGFloat = 280
        private let horizontalPadding: CGFloat = 12
        private let verticalPadding: CGFloat = 6

        init(summary: String) {
            self.summaryLabel = NSTextField(wrappingLabelWithString: summary)
            super.init(frame: .zero)

            summaryLabel.isEditable = false
            summaryLabel.isSelectable = false
            summaryLabel.isBordered = false
            summaryLabel.drawsBackground = false
            summaryLabel.lineBreakMode = .byWordWrapping
            summaryLabel.maximumNumberOfLines = 0
            summaryLabel.preferredMaxLayoutWidth = preferredTextWidth
            summaryLabel.font = .menuFont(ofSize: 13)
            summaryLabel.textColor = .textColor
            addSubview(summaryLabel)

            // Frame-based sizing — Auto Layout is unreliable for NSMenu view items
            let cellHeight = summaryLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: preferredTextWidth, height: .greatestFiniteMagnitude)).height
                ?? summaryLabel.fittingSize.height
            summaryLabel.frame = NSRect(x: horizontalPadding, y: verticalPadding, width: preferredTextWidth, height: ceil(cellHeight))
            frame = NSRect(
                x: 0, y: 0,
                width: preferredTextWidth + (horizontalPadding * 2),
                height: ceil(cellHeight) + (verticalPadding * 2)
            )
        }

        override var allowsVibrancy: Bool {
            true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class RecordingAttendeesMenuItemView: NSView {
        private let attendeesLabel: NSTextField
        private let preferredTextWidth: CGFloat = 280
        private let horizontalPadding: CGFloat = 12
        private let verticalPadding: CGFloat = 6

        init(attendeesText: String) {
            attendeesLabel = NSTextField(wrappingLabelWithString: attendeesText)
            super.init(frame: .zero)

            attendeesLabel.isEditable = false
            attendeesLabel.isSelectable = false
            attendeesLabel.isBordered = false
            attendeesLabel.drawsBackground = false
            attendeesLabel.lineBreakMode = .byWordWrapping
            attendeesLabel.maximumNumberOfLines = 0
            attendeesLabel.preferredMaxLayoutWidth = preferredTextWidth
            attendeesLabel.font = .menuFont(ofSize: 13)
            attendeesLabel.textColor = .disabledControlTextColor
            addSubview(attendeesLabel)

            // Frame-based sizing — Auto Layout is unreliable for NSMenu view items
            let cellHeight = attendeesLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: preferredTextWidth, height: .greatestFiniteMagnitude)).height
                ?? attendeesLabel.fittingSize.height
            attendeesLabel.frame = NSRect(x: horizontalPadding, y: verticalPadding, width: preferredTextWidth, height: ceil(cellHeight))
            frame = NSRect(
                x: 0, y: 0,
                width: preferredTextWidth + (horizontalPadding * 2),
                height: ceil(cellHeight) + (verticalPadding * 2)
            )
        }

        override var allowsVibrancy: Bool {
            true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class EventRecordingContext: NSObject {
        let eventID: String?
        let title: String
        let startDate: Date
        let endDate: Date?
        let attendees: [String]?
        let meetingURL: URL?
        let isRecurring: Bool

        init(
            eventID: String?,
            title: String,
            startDate: Date,
            endDate: Date?,
            attendees: [String]?,
            meetingURL: URL?,
            isRecurring: Bool
        ) {
            self.eventID = eventID
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.attendees = attendees
            self.meetingURL = meetingURL
            self.isRecurring = isRecurring
        }
    }

    private final class CalendarToggleButton: NSButton {
        let calendarIdentifier: String

        init(calendarIdentifier: String, title: String, state: NSControl.StateValue, target: AnyObject?, action: Selector) {
            self.calendarIdentifier = calendarIdentifier
            super.init(frame: .zero)
            setButtonType(.switch)
            self.title = title
            self.state = state
            self.target = target
            self.action = action
            font = .menuFont(ofSize: 0)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool {
            true
        }
    }

    private final class RecordingLocationContext: NSObject {
        let directoryURL: URL

        init(directoryURL: URL) {
            self.directoryURL = directoryURL
        }
    }

    private let calendarManager = CalendarManager()
    private let recordingStorage: RecordingStorage
    private let audioRecorder: AudioRecorder
    private let transcriptionManager: TranscriptionManager
    private let summaryManager: SummaryManager
    private let meetingEndDetector = MeetingEndDetector()
    private let meetingDetectionManager = MeetingDetectionManager()
    private let meetingReminderSuppressionInterval: TimeInterval = 120

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var didConfigure = false
    private var buttonConfigurationAttempts = 0

    private var stopRecordingMenuItem: NSMenuItem?
    private var recordingTimer: Timer?
    private var statusBarRecordingTimer: Timer?
    private var statusTextTimer: Timer?
    private var isMenuOpen = false
    private var recordingActionInFlight = false
    private var stopTransitionInFlight = false
    private var pendingTranscriptionStatus = false
    private var pendingSummaryStatus = false
    private var lastTranscriptionRebuild: Date = .distantPast
    private var currentRecordingState: RecordingState?
    private var transcriptionState: TranscriptionState = .idle
    private var summaryState: SummaryState = .noApiKey
    private var cachedRecentRecordings: [RecordingInfo] = []
    private var hasLoadedRecentRecordings = false
    private var isLoadingRecentRecordings = false
    private var recentRecordingsRefreshTask: Task<Void, Never>?
    private var calendarSelectionWindow: NSWindow?
    private var calendarSelectionScrollView: NSScrollView?
    private var calendarSelectionDocumentView: FlippedView?
    private var calendarSelectionPendingIdentifiers: Set<String>?
    private var calendarSelectionInitialIdentifiers: Set<String> = []
    private var calendarSelectionDidCommit: Bool = false
    private var lastCalendarReminderNotificationDate: Date?
    private var lastStatusItemIconOnlyMode: Bool?
    init(transcriptionManager: TranscriptionManager, summaryManager: SummaryManager, recordingStorage: RecordingStorage) {
        self.recordingStorage = recordingStorage
        self.audioRecorder = AudioRecorder(storage: recordingStorage)
        self.transcriptionManager = transcriptionManager
        self.summaryManager = summaryManager
        super.init()
    }

    func configure() {
        guard !didConfigure else {
            return
        }
        didConfigure = true

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.audioRecorder.setOnRecordingStateChanged { [weak self] state in
                guard let self else {
                    return
                }
                self.currentRecordingState = state

                if self.stopTransitionInFlight {
                    self.configureRecordingTimerIfNeeded()
                    self.configureStatusBarRecordingTimerIfNeeded()
                    return
                }
                self.updateStatusItemButtonAppearance()
                self.rebuildMenu()
                self.configureRecordingTimerIfNeeded()
                self.configureStatusBarRecordingTimerIfNeeded()
            }
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.audioRecorder.setOnSilenceDetected { [weak self] in
                NSLog("[SilenceDebug] MenuManager received combined silence callback from AudioRecorder")
                Task { @MainActor [weak self] in
                    self?.postSilenceDetectedNotification()
                }
            }
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.transcriptionManager.setOnStateChanged { [weak self] state in
                guard let self else {
                    return
                }
                let previousState = self.transcriptionState
                if case .transcribing = state {
                    let now = Date()
                    guard now.timeIntervalSince(self.lastTranscriptionRebuild) >= 1.0 else {
                        return
                    }
                    self.lastTranscriptionRebuild = now
                }
                self.transcriptionState = state
                switch state {
                case .transcribing:
                    self.pendingTranscriptionStatus = false
                    self.pendingSummaryStatus = false
                case .ready:
                    self.pendingTranscriptionStatus = false
                    if case .transcribing(let directoryURL, _) = previousState {
                        self.pendingSummaryStatus = self.shouldBridgeToSummaryStatus(for: directoryURL)
                    } else {
                        self.pendingSummaryStatus = false
                    }
                case .error:
                    self.pendingTranscriptionStatus = false
                    self.pendingSummaryStatus = false
                case .idle, .downloadingModel, .loadingModel:
                    break
                }
                switch state {
                case .ready, .error, .transcribing:
                    self.refreshRecentRecordings(force: true)
                    if case .ready = state {

                    } else if case .error = state {

                    }
                default:
                    break
                }
                self.updateStatusItemButtonAppearance()
                self.rebuildMenu()
            }
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.summaryManager.setOnStateChanged { [weak self] state in
                guard let self else {
                    return
                }
                self.summaryState = state
                if case .completed(let completedDirectoryURL) = state {
                    let storage = self.recordingStorage
                    Task.detached { [weak self] in
                        if await storage.collapseCompletedRecording(directoryURL: completedDirectoryURL) != nil {
                            DispatchQueue.main.async { [weak self] in
                                self?.refreshRecentRecordings(force: true)
                                self?.rebuildMenu()
                            }
                        }
                    }
                }
                switch state {
                case .idle, .generating, .completed, .error, .noApiKey:
                    self.pendingSummaryStatus = false
                }
                switch state {
                case .idle, .generating, .completed, .error, .noApiKey:
                    self.refreshRecentRecordings(force: true)
                    if case .generating = state {

                    } else if case .completed = state {

                    } else if case .error = state {

                    } else if case .noApiKey = state {

                    }
                }
                self.updateStatusItemButtonAppearance()
                self.rebuildMenu()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupStatusItem()
        startStatusTextTimer()
        rebuildMenu()
        calendarManager.setOnEventsChanged { [weak self] in
            self?.updateStatusItemButtonAppearance()
            if self?.isMenuOpen == true {
                self?.rebuildMenu()
            }
            self?.refreshCalendarSelectionWindowIfVisible()
        }
        calendarManager.requestAccessIfNeeded { [weak self] in
            self?.updateStatusItemButtonAppearance()
            self?.rebuildMenu()
            self?.refreshCalendarSelectionWindowIfVisible()
        }

        configureMeetingDetection()
    }

    @objc
    private func screenParametersDidChange() {
        updateStatusItemButtonAppearance()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusMenu else {
            return
        }
        isMenuOpen = true
        refreshRecentRecordings(force: true)
        rebuildMenu()
        configureRecordingTimerIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu == statusMenu {
            isMenuOpen = false
            stopRecordingTimer()
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === calendarSelectionWindow else {
            return
        }
        rebuildCalendarSelectionWindowContent()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === calendarSelectionWindow else {
            return
        }
        if !calendarSelectionDidCommit {
            revertCalendarSelectionToInitialState()
        }
        clearCalendarSelectionSession()
    }

    private func configureStatusItemButtonWithRetry() {
        guard let statusItem, statusItem.button != nil else {
            buttonConfigurationAttempts += 1
            if buttonConfigurationAttempts <= 10 {
                let attempt = buttonConfigurationAttempts
                NSLog("MeetingRecorder: status item button unavailable (attempt \(attempt)); retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.configureStatusItemButtonWithRetry()
                }
            } else {
                NSLog("MeetingRecorder: status item button unavailable after retries")
                if let statusItem {
                    NSStatusBar.system.removeStatusItem(statusItem)
                }
                self.statusItem = nil
                setupStatusItem()
            }
            return
        }

        updateStatusItemButtonAppearance()
    }

    private func setupStatusItem() {
        guard statusItem == nil else {
            return
        }

        statusMenu.delegate = self
        let createdItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        createdItem.menu = statusMenu
        createdItem.isVisible = true
        statusItem = createdItem
        NSLog("MeetingRecorder: status item created")

        configureStatusItemButtonWithRetry()
    }

    private func updateStatusItemButtonAppearance() {
        guard let statusItem, let button = statusItem.button else {
            return
        }

        let recordingImage = statusItemImage(named: "robot-recording", fallbackSystemSymbol: "waveform")
        let idleImage = statusItemImage(named: "robot-idle", fallbackSystemSymbol: "waveform.circle")
        let useIconOnlyMode = shouldUseIconOnlyStatusItem(for: button)
        if lastStatusItemIconOnlyMode != useIconOnlyMode {
            lastStatusItemIconOnlyMode = useIconOnlyMode
            let modeDescription = useIconOnlyMode ? "icon-only" : "icon+text"
            let screenName = button.window?.screen?.localizedName ?? "unknown"
            NSLog("MeetingRecorder: status item presentation mode changed to %@ (screen=%@)", modeDescription, screenName)
        }

        if stopTransitionInFlight {
            button.image = recordingImage
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            if useIconOnlyMode {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = "Stopping..."
                button.imagePosition = .imageLeading
            }
            button.toolTip = "Meeting Recorder: Stopping..."
            statusItem.length = useIconOnlyMode ? NSStatusItem.squareLength : NSStatusItem.variableLength
            return
        }

        if let recordingState = currentRecordingState {
            button.image = recordingImage
            button.contentTintColor = nil
            let elapsed = max(0, Date().timeIntervalSince(recordingState.startTime))
            let timestamp = formattedClockDuration(elapsed)
            if useIconOnlyMode {
                button.attributedTitle = NSAttributedString(string: "")
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                let prefix = "Listening "
                let attributed = NSMutableAttributedString(string: prefix)
                let monospacedFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                attributed.append(NSAttributedString(string: timestamp, attributes: [.font: monospacedFont]))
                button.attributedTitle = attributed
                button.imagePosition = .imageLeading
            }
            button.toolTip = "Meeting Recorder: Listening \(timestamp)"
            statusItem.length = useIconOnlyMode ? NSStatusItem.squareLength : NSStatusItem.variableLength
            return
        }

        if let processingStatusText = currentPostRecordingProcessingStatusText() {
            button.image = recordingImage
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            if useIconOnlyMode {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = processingStatusText
                button.imagePosition = .imageLeading
            }
            button.toolTip = "Meeting Recorder: \(processingStatusText)"
            statusItem.length = useIconOnlyMode ? NSStatusItem.squareLength : NSStatusItem.variableLength
            return
        }

        if recordingActionInFlight {
            button.image = recordingImage
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            if useIconOnlyMode {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = "Listening"
                button.imagePosition = .imageLeading
            }
            button.toolTip = "Meeting Recorder: Listening"
            statusItem.length = useIconOnlyMode ? NSStatusItem.squareLength : NSStatusItem.variableLength
            return
        }

        button.image = idleImage
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(string: "")

        if useIconOnlyMode {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "Meeting Recorder"
        } else {
            let statusText = currentStatusText()
            if statusText.isEmpty {
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.title = statusText
                button.imagePosition = .imageLeading
            }
            button.toolTip = statusText.isEmpty ? "Meeting Recorder" : "Meeting Recorder: \(statusText)"
        }

        if button.image == nil && button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            button.title = "MR"
            button.imagePosition = .noImage
            button.toolTip = "Meeting Recorder"
            NSLog("MeetingRecorder: status item image/title both empty; using text fallback")
        }
        statusItem.length = useIconOnlyMode ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    private func statusItemImage(named name: String, fallbackSystemSymbol: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }
        let fallback = NSImage(systemSymbolName: fallbackSystemSymbol, accessibilityDescription: "Meeting Recorder")
        if fallback == nil {
            NSLog("MeetingRecorder: failed to load status image '%@' and fallback symbol '%@'", name, fallbackSystemSymbol)
        } else {
            NSLog("MeetingRecorder: failed to load status image '%@'; using fallback symbol '%@'", name, fallbackSystemSymbol)
        }
        return fallback
    }

    private func shouldUseIconOnlyStatusItem(for button: NSStatusBarButton) -> Bool {
        guard let screen = button.window?.screen ?? NSScreen.main else {
            return false
        }
        return screenHasNotch(screen)
    }

    private func screenHasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea,
                  !left.isEmpty,
                  !right.isEmpty else {
                return false
            }
            return left.width + right.width < (screen.frame.width - 1.0)
        }
        return false
    }

    private func currentStatusText() -> String {
        guard calendarManager.currentAuthorizationState == .authorized else {
            return ""
        }

        let now = Date()
        let nextEvent = calendarManager.fetchTodaysEvents().first { $0.endDate > now }
        guard let nextEvent else {
            return "No events today"
        }

        let timeText = MenuDateFormatting.menuTimeString(from: nextEvent.startDate)
        let combined = "\(timeText) \(nextEvent.title)"
        return truncatedStatusText(combined)
    }

    private func truncatedStatusText(_ text: String, maxLength: Int = 30) -> String {
        guard text.count > maxLength else {
            return text
        }
        guard maxLength > 3 else {
            return String(text.prefix(maxLength))
        }
        return String(text.prefix(maxLength - 3)) + "..."
    }

    private func startStatusTextTimer() {
        guard statusTextTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 60.0, target: self, selector: #selector(statusTextTimerFired), userInfo: nil, repeats: true)
        statusTextTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func statusTextTimerFired() {
        calendarManager.refreshMeetingReminderNotifications()
        updateStatusItemButtonAppearance()
        if isMenuOpen {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        stopRecordingMenuItem = nil

        if let recordingState = currentRecordingState {
            let stopRecordingItem = makeStopRecordingMenuItem(for: recordingState)
            statusMenu.addItem(stopRecordingItem)
            stopRecordingMenuItem = stopRecordingItem

            if !recordingState.systemAudioEnabled {
                let warningItem = NSMenuItem(title: "Microphone only — system audio not available", action: nil, keyEquivalent: "")
                warningItem.isEnabled = false
                warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
                statusMenu.addItem(warningItem)
            } else if !recordingState.micAudioEnabled {
                let warningItem = NSMenuItem(title: "System audio only — microphone not available", action: nil, keyEquivalent: "")
                warningItem.isEnabled = false
                warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
                statusMenu.addItem(warningItem)
            }

            statusMenu.addItem(.separator())
        }

        addTranscriptionStatusSection()
        addCalendarSection()
        statusMenu.addItem(.separator())
        addRecentRecordingsSection()
        statusMenu.addItem(.separator())

        let newRecordingItem = NSMenuItem(
            title: recordingActionInFlight ? "Starting…" : "New Recording",
            action: #selector(startAdHocRecordingTapped),
            keyEquivalent: ""
        )
        newRecordingItem.target = self
        newRecordingItem.isEnabled = currentRecordingState == nil && !recordingActionInFlight
        statusMenu.addItem(newRecordingItem)

        let openRecordingsFolderItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        openRecordingsFolderItem.target = self
        statusMenu.addItem(openRecordingsFolderItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu()
        statusMenu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit Meeting Recorder",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func makeStopRecordingMenuItem(for recordingState: RecordingState) -> NSMenuItem {
        let item = NSMenuItem(
            title: stopRecordingTitle(for: recordingState),
            action: #selector(stopRecordingTapped),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = !recordingActionInFlight
        item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        return item
    }

    private func addCalendarSection() {
        switch calendarManager.currentAuthorizationState {
        case .authorized:
            let events = filteredUpcomingEvents(calendarManager.fetchTodaysEvents())

            statusMenu.addItem(makeSectionHeaderItem(title: "Upcoming Events"))

            if events.isEmpty {
                let emptyItem = NSMenuItem(title: "No more events today", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                statusMenu.addItem(emptyItem)
                return
            }

            for event in events {
                let eventItem = makeEventMenuItem(for: event)
                statusMenu.addItem(eventItem)
            }

        case .notDetermined:
            statusMenu.addItem(makeSectionHeaderItem(title: "Upcoming Events"))
            let pendingItem = NSMenuItem(title: "Requesting calendar access…", action: nil, keyEquivalent: "")
            pendingItem.isEnabled = false
            statusMenu.addItem(pendingItem)

        case .denied:
            statusMenu.addItem(makeSectionHeaderItem(title: "Upcoming Events"))
            let grantAccessItem = NSMenuItem(
                title: "Grant Calendar Access in System Settings",
                action: #selector(openCalendarPrivacySettings),
                keyEquivalent: ""
            )
            grantAccessItem.target = self
            statusMenu.addItem(grantAccessItem)
        }
    }

    private func filteredUpcomingEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { event in
            if let activeState = currentRecordingState,
               isEvent(event, currentlyRecordingWith: activeState) {
                return true
            }

            return !hasCompletedRecording(for: event)
        }
    }

    private func hasCompletedRecording(for event: CalendarEvent) -> Bool {
        cachedRecentRecordings.contains { recording in
            guard recording.calendarEvent else {
                return false
            }

            if let recordingEventID = recording.associatedCalendarEventID {
                return recordingEventID == event.id
            }

            // Backward compatibility for recordings created before event IDs were persisted.
            guard let associatedEventStartTime = recording.associatedEventStartTime,
                  let meetingTitle = recording.meetingTitle else {
                return false
            }
            let timeDelta = abs(event.startDate.timeIntervalSince(associatedEventStartTime))
            let titlesMatch = event.title.caseInsensitiveCompare(meetingTitle) == .orderedSame
            return titlesMatch && timeDelta < 1
        }
    }

    private func makeEventMenuItem(for event: CalendarEvent) -> NSMenuItem {
        let title = MenuDateFormatting.eventRowTitle(startDate: event.startDate, title: event.title)
        let eventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        eventItem.submenu = buildEventSubmenu(for: event)
        return eventItem
    }

    private func addRecentRecordingsSection() {
        statusMenu.addItem(makeSectionHeaderItem(title: "Recent Recordings"))

        let recentRecordings = cachedRecentRecordings
        if recentRecordings.isEmpty, isLoadingRecentRecordings, !hasLoadedRecentRecordings {
            let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            statusMenu.addItem(loadingItem)
            return
        }

        if recentRecordings.isEmpty {
            let noRecordingsItem = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            noRecordingsItem.isEnabled = false
            statusMenu.addItem(noRecordingsItem)
            return
        }

        for recording in recentRecordings {
            let displayDate = recordingMenuDisplayDate(for: recording)
            let rowTitle = MenuDateFormatting.recordingRowTitle(date: displayDate, title: recording.title) + recordingStatusSuffix(for: recording)
            let recordingItem = NSMenuItem(title: rowTitle, action: nil, keyEquivalent: "")
            recordingItem.submenu = buildRecordingSubmenu(for: recording)
            statusMenu.addItem(recordingItem)
        }
    }

    private func recordingMenuDisplayDate(for recording: RecordingInfo) -> Date {
        guard recording.calendarEvent,
              recording.meetingTitle != nil,
              let associatedEventStartTime = recording.associatedEventStartTime else {
            return recording.date
        }
        return associatedEventStartTime
    }

    private func recordingStatusSuffix(for recording: RecordingInfo) -> String {
        switch recording.transcriptionStatus {
        case "pending", "transcribing":
            return " — Transcribing…"
        case "failed":
            return " — Failed"
        default:
            break
        }
        switch recording.summaryStatus {
        case "generating":
            return " — Summarizing…"
        case "failed":
            return " — Summary Failed"
        case "no_api_key":
            return " — No API Key"
        default:
            return ""
        }
    }

    private func buildEventSubmenu(for event: CalendarEvent) -> NSMenu {
        let submenu = NSMenu(title: event.title)

        let startTime = MenuDateFormatting.menuTimeString(from: event.startDate)
        let endTime = MenuDateFormatting.menuTimeString(from: event.endDate)
        let timeRange = "\(startTime) – \(endTime)"
        let timeRangeItem = NSMenuItem(title: timeRange, action: nil, keyEquivalent: "")
        timeRangeItem.isEnabled = false
        submenu.addItem(timeRangeItem)

        if let attendeeCount = event.attendeeCount {
            let attendeeText = attendeeCount == 1 ? "1 attendee" : "\(attendeeCount) attendees"
            let attendeesItem = NSMenuItem(title: attendeeText, action: nil, keyEquivalent: "")
            attendeesItem.isEnabled = false
            submenu.addItem(attendeesItem)
        }

        submenu.addItem(.separator())

        if let activeState = currentRecordingState,
           isEvent(event, currentlyRecordingWith: activeState) {
            let recordingItem = NSMenuItem(title: "Recording...", action: nil, keyEquivalent: "")
            recordingItem.isEnabled = false
            submenu.addItem(recordingItem)
            return submenu
        }

        let actionTitle = event.meetingURL == nil ? "Start Recording" : "Open Meeting & Record"
        let actionSelector: Selector = event.meetingURL == nil
            ? #selector(startEventRecordingTapped)
            : #selector(openMeetingAndRecordEventTapped)
        let actionItem = NSMenuItem(title: actionTitle, action: actionSelector, keyEquivalent: "")
        actionItem.target = self
        actionItem.isEnabled = currentRecordingState == nil && !recordingActionInFlight
        actionItem.representedObject = EventRecordingContext(
            eventID: event.id,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            attendees: event.attendees,
            meetingURL: event.meetingURL,
            isRecurring: event.isRecurring
        )
        submenu.addItem(actionItem)

        return submenu
    }

    private func buildRecordingSubmenu(for recording: RecordingInfo) -> NSMenu {
        let submenu = NSMenu(title: recording.title)
        let recordingContext = RecordingLocationContext(directoryURL: recording.directoryURL)

        if recording.summaryStatus == "completed",
           let summary = recording.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            submenu.addItem(makeRecordingSummaryItem(summary: summary))

            let attendeeNames = recording.attendees
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !attendeeNames.isEmpty {
                submenu.addItem(makeRecordingAttendeesItem(attendeesText: attendeeNames.joined(separator: ", ")))
            }
        } else if recording.summaryStatus == "generating" {
            let generatingItem = NSMenuItem(title: "Generating summary...", action: nil, keyEquivalent: "")
            generatingItem.isEnabled = false
            submenu.addItem(generatingItem)
        } else if recording.summaryStatus == "failed" {
            let failedItem = NSMenuItem(title: "Summary Failed", action: nil, keyEquivalent: "")
            failedItem.isEnabled = false
            submenu.addItem(failedItem)
            let retryItem = NSMenuItem(title: "Retry Summary", action: #selector(retrySummaryTapped), keyEquivalent: "")
            retryItem.target = self
            retryItem.representedObject = recordingContext
            submenu.addItem(retryItem)
        } else if recording.summaryStatus == "no_api_key" {
            let noKeyItem = NSMenuItem(title: "No API Key", action: nil, keyEquivalent: "")
            noKeyItem.isEnabled = false
            submenu.addItem(noKeyItem)
            let retryItem = NSMenuItem(title: "Retry Summary", action: #selector(retrySummaryTapped), keyEquivalent: "")
            retryItem.target = self
            retryItem.representedObject = recordingContext
            submenu.addItem(retryItem)
        }

        submenu.addItem(.separator())

        if recording.transcriptionStatus == "failed" {
            let failedItem = NSMenuItem(title: "Transcription Failed", action: nil, keyEquivalent: "")
            failedItem.isEnabled = false
            submenu.addItem(failedItem)
            let retryItem = NSMenuItem(title: "Retry Transcription", action: #selector(retryTranscriptionTapped), keyEquivalent: "")
            retryItem.target = self
            retryItem.representedObject = recordingContext
            submenu.addItem(retryItem)
        } else if transcribingDirectoryURL == recording.directoryURL {
            let transcribingItem = NSMenuItem(title: "Transcribing...", action: nil, keyEquivalent: "")
            transcribingItem.isEnabled = false
            submenu.addItem(transcribingItem)
        } else if recording.hasTranscript {
            let copyTranscriptItem = NSMenuItem(
                title: "Copy Transcript",
                action: #selector(copyTranscriptTapped),
                keyEquivalent: ""
            )
            copyTranscriptItem.target = self
            copyTranscriptItem.representedObject = recordingContext
            submenu.addItem(copyTranscriptItem)
        } else {
            let noTranscriptItem = NSMenuItem(title: "No transcript", action: nil, keyEquivalent: "")
            noTranscriptItem.isEnabled = false
            submenu.addItem(noTranscriptItem)
        }

        let showInFinderItem = NSMenuItem(
            title: "Show in Finder",
            action: #selector(showRecordingInFinder),
            keyEquivalent: ""
        )
        showInFinderItem.target = self
        showInFinderItem.representedObject = recordingContext
        submenu.addItem(showInFinderItem)

        return submenu
    }

    private func buildSettingsSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Settings")

        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permissionsItem.submenu = buildPermissionsSubmenu()
        submenu.addItem(permissionsItem)

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = buildMicrophoneSubmenu()
        submenu.addItem(microphoneItem)

        submenu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLoginTapped),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLoginEnabled() ? .on : .off
        submenu.addItem(launchAtLoginItem)

        let detectMeetingsItem = NSMenuItem(
            title: "Detect Meetings Automatically",
            action: #selector(toggleMeetingAutoDetectionTapped),
            keyEquivalent: ""
        )
        detectMeetingsItem.target = self
        detectMeetingsItem.state = meetingDetectionManager.isEnabled ? .on : .off
        submenu.addItem(detectMeetingsItem)

        submenu.addItem(.separator())

        let selectCalendarsItem = NSMenuItem(title: "Select Calendars", action: #selector(openCalendarSelectionWindowTapped), keyEquivalent: "")
        selectCalendarsItem.target = self
        submenu.addItem(selectCalendarsItem)

        submenu.addItem(.separator())

        let apiKeyConfigured = if case .noApiKey = summaryState { false } else { true }
        let apiKeyItem = NSMenuItem(
            title: "API Key: \(apiKeyConfigured ? "Configured" : "Not Set")",
            action: #selector(setApiKeyTapped),
            keyEquivalent: ""
        )
        apiKeyItem.target = self
        submenu.addItem(apiKeyItem)

        let transcriptionModelItem = NSMenuItem(
            title: transcriptionModelStatusTitle(),
            action: #selector(transcriptionModelTapped),
            keyEquivalent: ""
        )
        transcriptionModelItem.target = self
        transcriptionModelItem.isEnabled = isTranscriptionModelItemEnabled()
        submenu.addItem(transcriptionModelItem)

        if let recordingState = currentRecordingState {
            submenu.addItem(.separator())
            let captureItem = NSMenuItem(
                title: activeCaptureTitle(for: recordingState),
                action: #selector(settingsInformationalItemTapped),
                keyEquivalent: ""
            )
            captureItem.target = self
            submenu.addItem(captureItem)
        }

        return submenu
    }

    private func makeSettingsPermissionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func buildPermissionsSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Permissions")

        let systemAudioGranted = UserDefaults.standard.bool(forKey: "systemAudioCaptureSucceeded")
        submenu.addItem(
            makeSettingsPermissionItem(
                title: "System Audio: \(systemAudioGranted ? "Granted" : "Not Granted")",
                action: #selector(openSystemAudioPrivacySettings)
            )
        )

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneGranted = microphoneStatus == .authorized
        submenu.addItem(
            makeSettingsPermissionItem(
                title: "Microphone: \(microphoneGranted ? "Granted" : "Not Granted")",
                action: #selector(openMicrophonePrivacySettings)
            )
        )

        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        submenu.addItem(
            makeSettingsPermissionItem(
                title: "Calendar: \(calendarAuthorizationTitle(for: calendarStatus))",
                action: #selector(openCalendarPrivacySettings)
            )
        )

        return submenu
    }

    private func buildMicrophoneSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Microphone")

        let storedUID = UserDefaults.standard.string(forKey: "selectedMicrophoneUID")
        let defaultDevice = systemDefaultInputDevice()
        let defaultName = defaultDevice?.name ?? "Unknown"

        let systemDefaultItem = NSMenuItem(
            title: "System Default (\(defaultName))",
            action: #selector(microphoneDeviceSelected(_:)),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.representedObject = "" as String
        systemDefaultItem.state = (storedUID == nil || storedUID?.isEmpty == true) ? .on : .off
        submenu.addItem(systemDefaultItem)

        submenu.addItem(.separator())

        let devices = availableInputDevices()
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(microphoneDeviceSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid as String
            item.state = (storedUID == device.uid) ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    @objc
    private func microphoneDeviceSelected(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        if uid.isEmpty {
            UserDefaults.standard.removeObject(forKey: "selectedMicrophoneUID")
        } else {
            UserDefaults.standard.set(uid, forKey: "selectedMicrophoneUID")
        }
        rebuildMenu()
    }

    @objc
    private func openCalendarSelectionWindowTapped(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            self?.showCalendarSelectionWindow()
        }
    }

    private func showCalendarSelectionWindow() {
        let window = makeCalendarSelectionWindowIfNeeded()
        if !window.isVisible || calendarSelectionPendingIdentifiers == nil {
            initializeCalendarSelectionSession()
        }
        rebuildCalendarSelectionWindowContent()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshCalendarSelectionWindowIfVisible() {
        guard let window = calendarSelectionWindow, window.isVisible else {
            return
        }
        rebuildCalendarSelectionWindowContent()
    }

    private func initializeCalendarSelectionSession() {
        calendarSelectionDidCommit = false

        guard calendarManager.currentAuthorizationState == .authorized else {
            calendarSelectionInitialIdentifiers = []
            calendarSelectionPendingIdentifiers = nil
            return
        }

        let calendars = calendarManager.availableEventCalendars()
        let allCalendarIdentifiers = Set(calendars.map(\.calendarIdentifier))
        let storedCalendarIdentifiers = calendarManager.storedEnabledCalendarIdentifiers() ?? allCalendarIdentifiers
        let initialIdentifiers = storedCalendarIdentifiers.intersection(allCalendarIdentifiers)

        calendarSelectionInitialIdentifiers = initialIdentifiers
        calendarSelectionPendingIdentifiers = initialIdentifiers
    }

    private func clearCalendarSelectionSession() {
        calendarSelectionInitialIdentifiers = []
        calendarSelectionPendingIdentifiers = nil
        calendarSelectionDidCommit = false
    }

    private func revertCalendarSelectionToInitialState() {
        guard calendarManager.currentAuthorizationState == .authorized else {
            return
        }
        let calendars = calendarManager.availableEventCalendars()
        let allCalendarIdentifiers = Set(calendars.map(\.calendarIdentifier))
        let restoredIdentifiers = calendarSelectionInitialIdentifiers.intersection(allCalendarIdentifiers)
        calendarManager.setEnabledCalendarIdentifiers(restoredIdentifiers)
        calendarManager.refreshMeetingReminderNotifications()
        updateStatusItemButtonAppearance()
        rebuildMenu()
    }

    private func makeCalendarSelectionWindowIfNeeded() -> NSWindow {
        if let calendarSelectionWindow {
            return calendarSelectionWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Select Calendars"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 300)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let descriptionLabel = NSTextField(wrappingLabelWithString: "Choose calendars to include in Upcoming Events and meeting reminders.")
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .tertiaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let documentView = FlippedView(frame: .zero)
        scrollView.documentView = documentView

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneCalendarSelectionTapped))
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(descriptionLabel)
        contentView.addSubview(scrollView)
        contentView.addSubview(doneButton)

        NSLayoutConstraint.activate([
            descriptionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            descriptionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            descriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -12),

            doneButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        calendarSelectionWindow = window
        calendarSelectionScrollView = scrollView
        calendarSelectionDocumentView = documentView
        return window
    }

    private func rebuildCalendarSelectionWindowContent() {
        guard let scrollView = calendarSelectionScrollView, let documentView = calendarSelectionDocumentView else {
            return
        }

        if calendarSelectionPendingIdentifiers == nil, calendarManager.currentAuthorizationState == .authorized {
            initializeCalendarSelectionSession()
        }

        documentView.subviews.forEach { $0.removeFromSuperview() }

        let contentWidth = max(260, scrollView.contentSize.width)
        let horizontalPadding: CGFloat = 20
        let headerIndent: CGFloat = horizontalPadding
        let rowIndent: CGFloat = horizontalPadding + 14
        let maxRowWidth = contentWidth - (rowIndent + horizontalPadding)
        var y: CGFloat = 8

        func addMessage(_ text: String, textColor: NSColor = .secondaryLabelColor) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.textColor = textColor
            label.maximumNumberOfLines = 0
            let fittingRect = NSRect(x: 0, y: 0, width: contentWidth - (horizontalPadding * 2), height: .greatestFiniteMagnitude)
            let labelHeight = ceil(label.cell?.cellSize(forBounds: fittingRect).height ?? label.fittingSize.height)
            label.frame = NSRect(x: horizontalPadding, y: y, width: fittingRect.width, height: labelHeight)
            documentView.addSubview(label)
            y += labelHeight + 10
        }

        func addSourceHeader(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(x: headerIndent, y: y, width: contentWidth - (horizontalPadding * 2), height: height)
            documentView.addSubview(label)
            y += height + 6
        }

        func addGroupSeparator() {
            y += 4
            let separator = NSBox(frame: NSRect(x: horizontalPadding, y: y, width: contentWidth - (horizontalPadding * 2), height: 1))
            separator.boxType = .separator
            documentView.addSubview(separator)
            y += 10
        }

        func addCalendarCheckbox(calendar: EKCalendar, pendingCalendarIdentifiers: Set<String>) {
            let title = calendarMenuTitle(for: calendar)
            let calendarIdentifier = calendar.calendarIdentifier
            let state: NSControl.StateValue = pendingCalendarIdentifiers.contains(calendarIdentifier) ? .on : .off
            let button = CalendarToggleButton(
                calendarIdentifier: calendarIdentifier,
                title: title,
                state: state,
                target: self,
                action: #selector(calendarSelectionCheckboxToggled)
            )
            button.frame = NSRect(x: rowIndent, y: y, width: maxRowWidth, height: max(22, ceil(button.fittingSize.height)))
            button.attributedTitle = attributedCalendarTitle(
                for: title,
                dotColor: NSColor(cgColor: calendar.cgColor),
                textColor: .labelColor
            )
            documentView.addSubview(button)
            y += button.frame.height + 5
        }

        guard calendarManager.currentAuthorizationState == .authorized else {
            addMessage("Calendar access is required to choose which calendars are included in Upcoming Events.")
            let button = NSButton(title: "Open Calendar Privacy Settings", target: self, action: #selector(openCalendarPrivacySettings))
            button.bezelStyle = .rounded
            button.frame = NSRect(
                x: horizontalPadding,
                y: y,
                width: max(220, ceil(button.fittingSize.width)),
                height: max(30, ceil(button.fittingSize.height))
            )
            documentView.addSubview(button)
            y += button.frame.height + 10
            documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(y + 8, scrollView.contentSize.height))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let calendars = calendarManager.availableEventCalendars()
        guard !calendars.isEmpty else {
            addMessage("No calendars are currently available.")
            documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(y + 8, scrollView.contentSize.height))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let pendingCalendarIdentifiers = calendarSelectionPendingIdentifiers
            ?? (calendarManager.storedEnabledCalendarIdentifiers() ?? Set(calendars.map(\.calendarIdentifier)))
        let calendarsBySourceIdentifier = Dictionary(grouping: calendars) { $0.source.sourceIdentifier }
        let orderedSources = calendarManager.availableEventCalendarSourcesInStoreOrder()

        var hasRenderedSourceGroup = false
        for source in orderedSources {
            guard let sourceCalendars = calendarsBySourceIdentifier[source.sourceIdentifier], !sourceCalendars.isEmpty else {
                continue
            }

            if hasRenderedSourceGroup {
                addGroupSeparator()
            }

            addSourceHeader(calendarSourceMenuTitle(for: source))

            let sortedSourceCalendars = sourceCalendars.sorted { lhs, rhs in
                calendarMenuTitle(for: lhs).localizedCaseInsensitiveCompare(calendarMenuTitle(for: rhs)) == .orderedAscending
            }

            for calendar in sortedSourceCalendars {
                addCalendarCheckbox(calendar: calendar, pendingCalendarIdentifiers: pendingCalendarIdentifiers)
            }

            hasRenderedSourceGroup = true
        }

        documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(y + 8, scrollView.contentSize.height))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func calendarMenuTitle(for calendar: EKCalendar) -> String {
        let trimmedTitle = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled Calendar" : trimmedTitle
    }

    private func calendarSourceMenuTitle(for source: EKSource) -> String {
        let trimmedTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled Account" : trimmedTitle
    }

    private func attributedCalendarTitle(for title: String, dotColor: NSColor?, textColor: NSColor) -> NSAttributedString {
        guard let dotColor else {
            return NSAttributedString(string: title, attributes: [.foregroundColor: textColor])
        }

        let dotAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: dotColor]
        let textAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
        let attributedTitle = NSMutableAttributedString(string: "● ", attributes: dotAttributes)
        attributedTitle.append(NSAttributedString(string: title, attributes: textAttributes))
        return attributedTitle
    }

    private func calendarAuthorizationTitle(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not Determined"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied"
        case .writeOnly:
            return "Write Only"
        case .fullAccess:
            return "Full Access"
        @unknown default:
            return "Unknown"
        }
    }

    private func activeCaptureTitle(for recordingState: RecordingState) -> String {
        switch (recordingState.systemAudioEnabled, recordingState.micAudioEnabled) {
        case (true, true):
            return "Capturing: System Audio + Microphone"
        case (false, true):
            return "Capturing: Microphone Only"
        case (true, false):
            return "Capturing: System Audio Only"
        case (false, false):
            return "Capturing: No Audio Sources"
        }
    }

    private func transcriptionModelStatusTitle() -> String {
        switch transcriptionState {
        case .idle:
            if transcriptionModelExistsOnDisk() {
                return "Transcription Model: Loading"
            }
            return "Transcription Model: Not Downloaded"
        case .loadingModel:
            return "Transcription Model: Loading"
        case .downloadingModel(let progress):
            return "Transcription Model: Downloading \(transcriptionDownloadProgressTitle(progress: progress))"
        case .ready, .transcribing:
            return "Transcription Model: Ready"
        case .error:
            return "Transcription Model: Error"
        }
    }

    private func transcriptionDownloadProgressTitle(progress: Double) -> String {
        let clampedProgress = max(0.0, min(progress, 1.0))
        let percent = Int(clampedProgress * 100.0)
        return "\(percent)%"
    }

    private func transcriptionModelExistsOnDisk() -> Bool {
        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(at: modelCacheDirectory, version: .v3)
    }

    private func isTranscriptionModelItemEnabled() -> Bool {
        switch transcriptionState {
        case .downloadingModel, .loadingModel, .transcribing:
            return false
        case .idle, .ready, .error:
            return true
        }
    }

    private func launchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func makeSectionHeaderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeRecordingSummaryItem(summary: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = RecordingSummaryMenuItemView(summary: summary)
        return item
    }

    private func makeRecordingAttendeesItem(attendeesText: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = RecordingAttendeesMenuItemView(attendeesText: attendeesText)
        return item
    }

    private func stopRecordingTitle(for recordingState: RecordingState) -> String {
        if recordingActionInFlight {
            return "Stop Recording · Stopping..."
        }
        let elapsed = max(0, Date().timeIntervalSince(recordingState.startTime))
        return "Stop Recording · \(formattedClockDuration(elapsed))"
    }

    private func formattedClockDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func currentPostRecordingProcessingStatusText() -> String? {
        if pendingTranscriptionStatus {
            return "Transcribing"
        }
        if case .transcribing = transcriptionState {
            return "Transcribing"
        }
        if pendingSummaryStatus {
            return "Summarizing"
        }
        if case .generating = summaryState {
            return "Summarizing"
        }
        return nil
    }

    private func shouldBridgeToSummaryStatus(for directoryURL: URL) -> Bool {
        if case .noApiKey = summaryState {
            return false
        }

        let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
        return FileManager.default.fileExists(atPath: transcriptURL.path)
    }

    private var transcribingDirectoryURL: URL? {
        if case .transcribing(let directoryURL, _) = transcriptionState {
            return directoryURL
        }
        return nil
    }

    private func isEvent(_ event: CalendarEvent, currentlyRecordingWith state: RecordingState) -> Bool {
        guard state.calendarEvent else {
            return false
        }

        if let associatedCalendarEventID = state.associatedCalendarEventID {
            return associatedCalendarEventID == event.id
        }

        guard let associatedEventStartTime = state.associatedEventStartTime else {
            return false
        }
        let timeDelta = abs(event.startDate.timeIntervalSince(associatedEventStartTime))
        let titlesMatch = event.title.caseInsensitiveCompare(state.displayTitle) == .orderedSame
        return titlesMatch && timeDelta < 1
    }

    private func configureRecordingTimerIfNeeded() {
        let shouldRunTimer = isMenuOpen && currentRecordingState != nil
        if shouldRunTimer {
            guard recordingTimer == nil else {
                return
            }
            let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(recordingTimerFired), userInfo: nil, repeats: true)
            recordingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        stopRecordingTimer()
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func configureStatusBarRecordingTimerIfNeeded() {
        if currentRecordingState != nil {
            guard statusBarRecordingTimer == nil else {
                return
            }
            let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(statusBarRecordingTimerFired), userInfo: nil, repeats: true)
            statusBarRecordingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            stopStatusBarRecordingTimer()
        }
    }

    private func stopStatusBarRecordingTimer() {
        statusBarRecordingTimer?.invalidate()
        statusBarRecordingTimer = nil
    }

    @objc
    private func statusBarRecordingTimerFired() {
        guard currentRecordingState != nil else {
            stopStatusBarRecordingTimer()
            return
        }
        updateStatusItemButtonAppearance()
    }

    @objc
    private func recordingTimerFired() {
        guard let recordingState = currentRecordingState else {
            stopRecordingTimer()
            return
        }

        if let stopRecordingMenuItem {
            stopRecordingMenuItem.title = stopRecordingTitle(for: recordingState)
        } else {
            rebuildMenu()
        }
    }

    @objc
    private func startAdHocRecordingTapped(_ sender: Any?) {
        startFreshRecording()
    }

    @objc
    private func startEventRecordingTapped(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? EventRecordingContext else {
            NSSound.beep()
            return
        }
        startRecording(for: context, openMeetingURL: false)
    }

    @objc
    private func openMeetingAndRecordEventTapped(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? EventRecordingContext else {
            NSSound.beep()
            return
        }
        startRecording(for: context, openMeetingURL: true)
    }

    func startRecordingFromMeetingReminder(_ context: MeetingReminderNotification.EventContext) {
        let eventContext = EventRecordingContext(
            eventID: context.eventID,
            title: context.title,
            startDate: context.startDate,
            endDate: context.endDate,
            attendees: context.attendees,
            meetingURL: context.meetingURL,
            isRecurring: context.isRecurring
        )
        startRecording(for: eventContext, openMeetingURL: true)
    }

    func startRecordingFromMeetingDetectedNotification(userInfo: [AnyHashable: Any]) {
        let bundleID = MeetingDetectedNotification.bundleID(from: userInfo) ?? "unknown"
        let appName = MeetingDetectedNotification.appName(from: userInfo) ?? "unknown app"
        NSLog("MeetingRecorder: starting recording from meeting detection notification for %@ (%@)", appName, bundleID)
        startFreshRecording()
    }

    func markCalendarReminderNotificationDelivered() {
        lastCalendarReminderNotificationDate = Date()
    }

    private func startRecording(for context: EventRecordingContext, openMeetingURL: Bool) {
        if openMeetingURL, let meetingURL = context.meetingURL {
            NSWorkspace.shared.open(meetingURL)
        }
        beginStartRecording(
            eventTitle: context.title,
            attendees: context.attendees,
            startTime: Date(),
            associatedEventStartTime: context.startDate,
            calendarEventEndDate: context.endDate,
            associatedCalendarEventID: context.eventID,
            calendarEvent: true,
            isRecurring: context.isRecurring
        )
    }

    func startFreshRecording() {
        beginStartRecording(
            eventTitle: nil,
            attendees: nil,
            startTime: Date(),
            associatedEventStartTime: nil,
            calendarEventEndDate: nil,
            associatedCalendarEventID: nil,
            calendarEvent: false,
            isRecurring: false
        )
    }

    private func beginStartRecording(
        eventTitle: String?,
        attendees: [String]?,
        startTime: Date,
        associatedEventStartTime: Date?,
        calendarEventEndDate: Date?,
        associatedCalendarEventID: String?,
        calendarEvent: Bool,
        isRecurring: Bool
    ) {
        guard currentRecordingState == nil, !recordingActionInFlight else {
            return
        }

        clearMeetingDetectedNotifications()
        recordingActionInFlight = true
        updateStatusItemButtonAppearance()
        rebuildMenu()

        Task { [weak self] in
            guard let self else {
                return
            }

            var didStartRecording = false
            do {
                try await self.audioRecorder.startRecording(
                    eventTitle: eventTitle,
                    attendees: attendees,
                    startTime: startTime,
                    associatedEventStartTime: associatedEventStartTime,
                    associatedCalendarEventID: associatedCalendarEventID,
                    calendarEvent: calendarEvent,
                    isRecurring: isRecurring
                )
                didStartRecording = true

                if let state = await self.audioRecorder.currentRecordingState() {
                    self.showSourceFailureAlertIfNeeded(for: state)
                }
            } catch {
                if case AudioRecorderError.noAudioSourcesAvailable = error {
                    self.showBothSourcesFailedAlert()
                } else {
                    NSSound.beep()
                }
                NSLog("MeetingRecorder: start recording failed: \(error.localizedDescription)")
            }

            self.recordingActionInFlight = false
            self.updateStatusItemButtonAppearance()
            self.rebuildMenu()
            self.configureRecordingTimerIfNeeded()

            if didStartRecording {
                self.meetingEndDetector.delegate = self
                self.meetingEndDetector.startMonitoring(
                    calendarEventEndDate: calendarEventEndDate,
                    calendarEventID: associatedCalendarEventID
                )
            }
        }
    }

    @objc
    private func stopRecordingTapped(_ sender: Any?) {
        beginStopRecording(shouldTranscribe: true)
    }

    func stopRecordingFromNotificationAction() {
        beginStopRecording(shouldTranscribe: true)
    }

    private func beginStopRecording(shouldTranscribe: Bool) {
        guard currentRecordingState != nil, !recordingActionInFlight else {
            return
        }

        meetingEndDetector.stopMonitoring()
        stopStatusBarRecordingTimer()
        stopRecordingTimer()

        stopTransitionInFlight = true
        pendingTranscriptionStatus = false
        pendingSummaryStatus = false
        recordingActionInFlight = true
        rebuildMenu()
        updateStatusItemButtonAppearance()

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let stoppedDirectoryURL = try await self.audioRecorder.stopRecording()
                let directoryURL = await self.recordingStorage.renameDirectoryUsingStoredTitle(directoryURL: stoppedDirectoryURL)
                self.clearSilenceDetectionNotifications()
                self.currentRecordingState = nil
                self.stopTransitionInFlight = false
                self.pendingTranscriptionStatus = shouldTranscribe
                self.recordingActionInFlight = false
                self.updateStatusItemButtonAppearance()
                self.rebuildMenu()
                self.configureRecordingTimerIfNeeded()
                self.configureStatusBarRecordingTimerIfNeeded()
                self.refreshRecentRecordings(force: true)


                if shouldTranscribe {
                    Task {
                        await self.transcriptionManager.transcribe(directoryURL: directoryURL)
                    }
                }
                return
            } catch {
                NSSound.beep()
                NSLog("MeetingRecorder: stop recording failed: \(error.localizedDescription)")
            }

            self.stopTransitionInFlight = false
            self.pendingTranscriptionStatus = false
            self.recordingActionInFlight = false
            self.updateStatusItemButtonAppearance()
            self.rebuildMenu()
            self.configureRecordingTimerIfNeeded()
            self.configureStatusBarRecordingTimerIfNeeded()
        }
    }

    private func postSilenceDetectedNotification() {
        guard currentRecordingState != nil else {
            NSLog("MeetingRecorder: silence notification skipped (no active recording)")
            return
        }
        NSLog("[SilenceDebug] MenuManager preparing silence-detected user notification")

        let center = UNUserNotificationCenter.current()
        let identifier = SilenceDetectionNotification.requestIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Still in a meeting?"
        content.body = "No audio detected for 60 seconds."
        content.categoryIdentifier = SilenceDetectionNotification.categoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        NSLog("[SilenceDebug] MenuManager calling UNUserNotificationCenter.add for identifier=%@", identifier)
        center.add(request) { error in
            if let error {
                NSLog("[SilenceDebug] MenuManager UNUserNotificationCenter.add completed with error: %@", error.localizedDescription)
            } else {
                NSLog("[SilenceDebug] MenuManager UNUserNotificationCenter.add completed successfully")
            }
        }
    }

    private func postMeetingDetectedNotification(appName: String, bundleID: String) {
        guard currentRecordingState == nil else {
            return
        }
        guard !isMeetingDetectionSuppressedByRecentCalendarReminder() else {
            NSLog("MeetingRecorder: meeting detection notification suppressed due to recent calendar reminder")
            return
        }

        let center = UNUserNotificationCenter.current()
        let identifier = MeetingDetectedNotification.requestIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "It looks like you're in a call on \(appName). Would you like to start recording?"
        content.categoryIdentifier = MeetingDetectedNotification.categoryIdentifier
        content.sound = .default
        content.userInfo = MeetingDetectedNotification.userInfo(bundleID: bundleID, appName: appName)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("MeetingRecorder: failed to post meeting detected notification: %@", error.localizedDescription)
            }
        }
    }

    private func clearSilenceDetectionNotifications() {
        let center = UNUserNotificationCenter.current()
        let identifier = SilenceDetectionNotification.requestIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func clearMeetingDetectedNotifications() {
        let center = UNUserNotificationCenter.current()
        let identifier = MeetingDetectedNotification.requestIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    @objc
    private func showRecordingInFinder(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RecordingLocationContext else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([context.directoryURL])
    }

    @objc
    private func openRecordingsFolder(_ sender: Any?) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.recordingStorage.ensureRootDirectoryExists()
                NSWorkspace.shared.open(self.recordingStorage.rootURL)
            } catch {
                NSSound.beep()
                NSLog("Failed to create/open recordings folder: \(error.localizedDescription)")
            }
        }
    }

    @objc
    private func calendarSelectionCheckboxToggled(_ sender: NSButton) {
        guard let sender = sender as? CalendarToggleButton else {
            NSSound.beep()
            return
        }

        guard var pendingCalendarIdentifiers = calendarSelectionPendingIdentifiers else {
            return
        }

        if sender.state == .on {
            pendingCalendarIdentifiers.insert(sender.calendarIdentifier)
        } else {
            pendingCalendarIdentifiers.remove(sender.calendarIdentifier)
        }

        calendarSelectionPendingIdentifiers = pendingCalendarIdentifiers
    }

    @objc
    private func doneCalendarSelectionTapped(_ sender: Any?) {
        guard calendarManager.currentAuthorizationState == .authorized else {
            calendarSelectionWindow?.performClose(nil)
            return
        }

        let calendars = calendarManager.availableEventCalendars()
        let allCalendarIdentifiers = Set(calendars.map(\.calendarIdentifier))
        let pendingCalendarIdentifiers = calendarSelectionPendingIdentifiers
            ?? (calendarManager.storedEnabledCalendarIdentifiers() ?? allCalendarIdentifiers)
        let finalEnabledCalendarIdentifiers = pendingCalendarIdentifiers.intersection(allCalendarIdentifiers)
        calendarManager.setEnabledCalendarIdentifiers(finalEnabledCalendarIdentifiers)
        calendarManager.refreshMeetingReminderNotifications()
        updateStatusItemButtonAppearance()
        rebuildMenu()

        calendarSelectionDidCommit = true
        calendarSelectionWindow?.performClose(nil)
    }

    @objc
    private func toggleLaunchAtLoginTapped(_ sender: Any?) {
        do {
            if launchAtLoginEnabled() {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MeetingRecorder: failed to toggle launch at login: \(error.localizedDescription)")
            NSSound.beep()
        }

        rebuildMenu()
    }

    @objc
    private func toggleMeetingAutoDetectionTapped(_ sender: Any?) {
        meetingDetectionManager.isEnabled.toggle()
        if meetingDetectionManager.isEnabled {
            meetingDetectionManager.startMonitoring()
        } else {
            meetingDetectionManager.stopMonitoring()
        }
        rebuildMenu()
    }

    @objc
    private func transcriptionModelTapped(_ sender: Any?) {
        switch transcriptionState {
        case .downloadingModel, .loadingModel, .transcribing:
            return
        case .idle:
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.transcriptionManager.preloadModel()
            }
        case .ready:
            showReadyTranscriptionModelAlert()
        case .error:
            showErroredTranscriptionModelAlert()
        }
    }

    @objc
    private func settingsInformationalItemTapped(_ sender: Any?) {
        // Enabled no-op to keep informational rows clickable.
    }

    @objc
    private func openSystemAudioPrivacySettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func openMicrophonePrivacySettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func openCalendarPrivacySettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func copyTranscriptTapped(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RecordingLocationContext else {
            NSSound.beep()
            return
        }

        let transcriptURL: URL
        if context.directoryURL.pathExtension == "txt" {
            transcriptURL = context.directoryURL
        } else {
            transcriptURL = context.directoryURL.appendingPathComponent("transcript.txt")
        }

        guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            NSSound.beep()
            NSLog("MeetingRecorder: failed to read transcript file")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private nonisolated static func extractTranscriptBody(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var foundBlankLine = false
        var headerEnded = false
        var bodyLines: [String] = []

        for line in lines {
            if headerEnded {
                bodyLines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if foundBlankLine || bodyLines.isEmpty {
                    headerEnded = true
                }
                foundBlankLine = true
            } else {
                foundBlankLine = false
            }
        }

        return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showReadyTranscriptionModelAlert() {
        let modelSizeBytes = Self.transcriptionModelCacheSizeBytes()
        let formattedModelSize = ByteCountFormatter.string(fromByteCount: modelSizeBytes, countStyle: .file)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Transcription Model"
        alert.informativeText = "Parakeet TDT v3\n\(formattedModelSize) on disk"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Delete Model")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.transcriptionManager.deleteModelCache()
            } catch {
                NSLog("MeetingRecorder: failed to delete transcription model: \(error.localizedDescription)")
                NSSound.beep()
            }
            self.rebuildMenu()
        }
    }

    private func showErroredTranscriptionModelAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Transcription Model"
        alert.informativeText = "Parakeet TDT v3\nFailed to load"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Retry")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            await self.transcriptionManager.preloadModel()
        }
    }

    private nonisolated static func transcriptionModelCacheSizeBytes() -> Int64 {
        let fileManager = FileManager.default
        let modelCacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        let fileResourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: modelCacheDirectory,
            includingPropertiesForKeys: Array(fileResourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: fileResourceKeys), values.isRegularFile == true else {
                continue
            }
            let fileSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            totalBytes += Int64(fileSize)
        }

        return totalBytes
    }

    private func addTranscriptionStatusSection() {
        switch transcriptionState {
        case .downloadingModel(let progress):
            let progressTitle = transcriptionDownloadProgressTitle(progress: progress)
            let item = NSMenuItem(title: "Downloading transcription model… \(progressTitle)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.addItem(item)
            statusMenu.addItem(.separator())
        case .loadingModel:
            let item = NSMenuItem(title: "Loading transcription model...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.addItem(item)
            statusMenu.addItem(.separator())
        default:
            break
        }
    }

    private func refreshRecentRecordings(force: Bool = false) {
        if force {
            recentRecordingsRefreshTask?.cancel()
            recentRecordingsRefreshTask = nil
        } else if recentRecordingsRefreshTask != nil {
            return
        }

        isLoadingRecentRecordings = true

        recentRecordingsRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            let recordings = await self.recordingStorage.listRecentRecordings(days: 7)
            guard !Task.isCancelled else {
                return
            }

            self.cachedRecentRecordings = recordings
            self.hasLoadedRecentRecordings = true
            self.isLoadingRecentRecordings = false
            self.recentRecordingsRefreshTask = nil
            if self.isMenuOpen {
                self.rebuildMenu()
            }
        }
    }

    var isRecordingActive: Bool {
        currentRecordingState != nil
    }

    var activeRecordingDirectoryURL: URL? {
        currentRecordingState?.recordingDirectoryURL
    }

    func stopRecordingForTermination() async -> URL? {
        guard currentRecordingState != nil else {
            return nil
        }

        recordingActionInFlight = true
        rebuildMenu()

        defer {
            recordingActionInFlight = false
            updateStatusItemButtonAppearance()
            rebuildMenu()
            configureRecordingTimerIfNeeded()
        }

        do {
            let stoppedDirectoryURL = try await audioRecorder.stopRecording()
            let directoryURL = await recordingStorage.renameDirectoryUsingStoredTitle(directoryURL: stoppedDirectoryURL)
            clearSilenceDetectionNotifications()
            return directoryURL
        } catch {
            NSLog("MeetingRecorder: stop recording during termination failed: \(error.localizedDescription)")
            return nil
        }
    }

    @objc
    private func retryTranscriptionTapped(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RecordingLocationContext else {
            NSSound.beep()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionManager.transcribe(directoryURL: context.directoryURL)
        }
    }

    @objc
    private func retrySummaryTapped(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RecordingLocationContext else {
            NSSound.beep()
            return
        }
        retrySummaryGeneration(directoryURL: context.directoryURL)
    }

    private func retrySummaryGeneration(directoryURL: URL) {
        if directoryURL.pathExtension == "txt" {
            return
        }

        let recordingStorage = self.recordingStorage
        let summaryManager = self.summaryManager

        Task.detached {
            let transcriptURL = directoryURL.appendingPathComponent("transcript.txt")
            guard let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                NSLog("MeetingRecorder: retry summary failed — could not read transcript for \(directoryURL.lastPathComponent)")
                return
            }

            let body = MenuManager.extractTranscriptBody(from: content)
            let transcript = body.isEmpty ? content : body
            let recordingInfo = await recordingStorage.recordingInfo(for: directoryURL)
            let meetingTitle = recordingInfo?.summaryPromptTitle
            let attendees = recordingInfo?.attendees

            await summaryManager.generateSummary(
                directoryURL: directoryURL,
                transcript: transcript,
                meetingTitle: meetingTitle,
                attendees: attendees
            )
        }
    }

    @objc
    private func setApiKeyTapped(_ sender: Any?) {
        guard let key = SummaryManager.promptForApiKey() else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.summaryManager.setApiKey(key)

            let pendingRecordings = self.cachedRecentRecordings.filter {
                $0.summaryStatus == "no_api_key" && $0.transcriptionStatus == "completed"
            }
            for recording in pendingRecordings {
                self.retrySummaryGeneration(directoryURL: recording.directoryURL)
            }
        }
    }

    private func showSourceFailureAlertIfNeeded(for recordingState: RecordingState) {
        if !recordingState.systemAudioEnabled && recordingState.micAudioEnabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "System Audio Not Available"
            alert.informativeText = "Only your microphone is being recorded. Audio from other meeting participants won't be captured.\n\nTo record system audio, grant System Audio Recording permission in System Settings. You may need to restart Meeting Recorder after granting permission."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Open System Settings")

            if alert.runModal() == .alertSecondButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if recordingState.systemAudioEnabled && !recordingState.micAudioEnabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Microphone Not Available"
            alert.informativeText = "Only system audio is being recorded. Your voice may not be clearly captured.\n\nTo record your microphone, grant Microphone permission in System Settings."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Open System Settings")

            if alert.runModal() == .alertSecondButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showBothSourcesFailedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording Failed"
        alert.informativeText = "Neither system audio nor microphone are available. Check System Audio Recording and Microphone permissions in System Settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")

        if alert.runModal() == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func configureMeetingDetection() {
        meetingDetectionManager.isRecordingActive = { [weak self] in
            guard let self else {
                return false
            }
            return self.currentRecordingState != nil || self.isMeetingDetectionSuppressedByRecentCalendarReminder()
        }

        meetingDetectionManager.onMeetingDetected = { [weak self] detection in
            guard let self else {
                return
            }
            self.postMeetingDetectedNotification(appName: detection.detectedAppName, bundleID: detection.bundleID)
        }

        if meetingDetectionManager.isEnabled {
            meetingDetectionManager.startMonitoring()
        } else {
            meetingDetectionManager.stopMonitoring()
        }
    }

    private func isMeetingDetectionSuppressedByRecentCalendarReminder(referenceDate: Date = Date()) -> Bool {
        guard let lastCalendarReminderNotificationDate else {
            return false
        }
        return referenceDate.timeIntervalSince(lastCalendarReminderNotificationDate) < meetingReminderSuppressionInterval
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

extension MenuManager: MeetingEndDetectorDelegate {
    func meetingEndDetectorDidDetectMeetingEnded(_ detector: MeetingEndDetector) {
        guard isRecordingActive else {
            return
        }

        beginStopRecording(shouldTranscribe: true)

        let center = UNUserNotificationCenter.current()
        let identifier = MeetingEndNotification.requestIdentifier
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Meeting ended"
        content.body = "Transcribing your recording."
        content.categoryIdentifier = MeetingEndNotification.categoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("MeetingRecorder: failed to post meeting ended notification: %@", error.localizedDescription)
            }
        }
    }

    func meetingEndDetectorDidPassCalendarEndTime(_ detector: MeetingEndDetector) {
        Task {
            await audioRecorder.reduceSilenceThresholds()
        }
    }
}
