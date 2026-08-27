import AppKit
import CoreAudio
import CoreGraphics
import Foundation

@MainActor
final class MeetingDetectionManager {
    /// Called when a meeting is detected. Provides the app name and bundle ID.
    var onMeetingDetected: ((detectedAppName: String, bundleID: String)) -> Void = { _ in }

    /// Set this so detection is suppressed during active recording.
    var isRecordingActive: () -> Bool = { false }

    /// Whether detection is enabled (user preference).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else {
                return
            }

            userDefaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                cancelPendingDetection()
            } else if isMonitoring {
                evaluateCurrentMicState()
            }
        }
    }

    private enum DetectionConfidence {
        case high
        case medium

        var debounceNanoseconds: UInt64 {
            switch self {
            case .high:
                return 4_000_000_000
            case .medium:
                return 8_000_000_000
            }
        }

        var priority: Int {
            switch self {
            case .high:
                return 2
            case .medium:
                return 1
            }
        }
    }

    private enum ProcessCategory {
        case meetingApp(name: String)
        case browser
    }

    private struct ActiveInputProcess {
        let pid: pid_t
        let bundleID: String
        let category: ProcessCategory
    }

    private struct DetectionCandidate {
        let pid: pid_t
        let bundleID: String
        let appName: String
        let confidence: DetectionConfidence
        let appPriority: Int
    }

    private struct WindowInfo {
        let pid: pid_t
        let ownerName: String
        let title: String
    }

    private static let enabledDefaultsKey = "meetingAutoDetectionEnabled"
    private static let cooldownInterval: TimeInterval = 300

    private static let zoomBundleID = "us.zoom.xos"
    private static let teamsBundleID = "com.microsoft.teams2"
    private static let slackBundleID = "com.tinyspeck.slackmacgap"
    private static let faceTimeBundleID = "com.apple.FaceTime"
    private static let discordBundleID = "com.hnc.Discord"

    private static let knownMeetingApps: [String: String] = [
        zoomBundleID: "Zoom",
        teamsBundleID: "Microsoft Teams",
        slackBundleID: "Slack",
        faceTimeBundleID: "FaceTime",
        discordBundleID: "Discord"
    ]

    private static let knownBrowserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser"
    ]

    private static let appPriority: [String: Int] = [
        zoomBundleID: 0,
        teamsBundleID: 1,
        slackBundleID: 2,
        faceTimeBundleID: 3,
        discordBundleID: 4
    ]

    private static let googleMeetCodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\bMeet - [a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}\b"#
    )

    private static let teamsNonMeetingTitles: Set<String> = [
        "activity",
        "chat",
        "teams",
        "calendar",
        "calls",
        "files",
        "microsoft teams"
    ]

    private let userDefaults: UserDefaults
    private let listenerQueue = DispatchQueue(label: "MeetingRecorder.MeetingDetectionManager.CoreAudio")

    private var isMonitoring = false
    private var monitoredInputDeviceID: AudioDeviceID?
    private var defaultInputDeviceListener: AudioObjectPropertyListenerBlock?
    private var inputRunningListener: AudioObjectPropertyListenerBlock?
    private var pendingDetectionTask: Task<Void, Never>?
    private var pendingDetectionBundleID: String?
    private var cooldownByBundleID: [String: Date] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        userDefaults.register(defaults: [Self.enabledDefaultsKey: true])
        self.isEnabled = userDefaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        isMonitoring = true
        installDefaultInputDeviceListener()
        refreshInputDeviceListener()
        evaluateCurrentMicState()
    }

    func stopMonitoring() {
        guard isMonitoring else {
            return
        }

        cancelPendingDetection()
        uninstallInputRunningListener()
        uninstallDefaultInputDeviceListener()
        monitoredInputDeviceID = nil
        isMonitoring = false
    }

    private func installDefaultInputDeviceListener() {
        guard defaultInputDeviceListener == nil else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleDefaultInputDeviceChanged()
            }
        }

        var address = defaultInputDeviceAddress()
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &address,
            listenerQueue,
            listener
        )
        guard status == noErr else {
            logCoreAudioError("Failed to add default input-device listener", status: status)
            return
        }

        defaultInputDeviceListener = listener
    }

    private func uninstallDefaultInputDeviceListener() {
        guard let listener = defaultInputDeviceListener else {
            return
        }

        var address = defaultInputDeviceAddress()
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectRemovePropertyListenerBlock(
            systemObjectID,
            &address,
            listenerQueue,
            listener
        )
        if status != noErr {
            logCoreAudioError("Failed to remove default input-device listener", status: status)
        }

        defaultInputDeviceListener = nil
    }

    private func refreshInputDeviceListener() {
        uninstallInputRunningListener()

        guard let defaultInputDeviceID = currentDefaultInputDeviceID() else {
            monitoredInputDeviceID = nil
            return
        }

        monitoredInputDeviceID = defaultInputDeviceID
        installInputRunningListener(for: defaultInputDeviceID)
    }

    private func installInputRunningListener(for deviceID: AudioDeviceID) {
        guard inputRunningListener == nil else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleInputDeviceRunningStateChanged(for: deviceID)
            }
        }

        var address = deviceIsRunningAddress()
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            listener
        )
        guard status == noErr else {
            logCoreAudioError("Failed to add mic-running listener", status: status)
            return
        }

        inputRunningListener = listener
    }

    private func uninstallInputRunningListener() {
        guard let deviceID = monitoredInputDeviceID,
              let listener = inputRunningListener else {
            inputRunningListener = nil
            return
        }

        var address = deviceIsRunningAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            listener
        )
        if status != noErr {
            logCoreAudioError("Failed to remove mic-running listener", status: status)
        }

        inputRunningListener = nil
    }

    private func handleDefaultInputDeviceChanged() {
        guard isMonitoring else {
            return
        }

        cancelPendingDetection()
        refreshInputDeviceListener()
        evaluateCurrentMicState()
    }

    private func handleInputDeviceRunningStateChanged(for deviceID: AudioDeviceID) {
        guard isMonitoring, isEnabled else {
            cancelPendingDetection()
            return
        }

        guard deviceID == monitoredInputDeviceID else {
            return
        }

        guard let isRunning = isDeviceRunningSomewhere(deviceID) else {
            return
        }

        if isRunning {
            identifyAndScheduleDetection()
        } else {
            cancelPendingDetection()
        }
    }

    private func evaluateCurrentMicState() {
        guard isMonitoring, isEnabled else {
            return
        }

        guard let inputDeviceID = monitoredInputDeviceID,
              let isRunning = isDeviceRunningSomewhere(inputDeviceID) else {
            return
        }

        if isRunning {
            identifyAndScheduleDetection()
        } else {
            cancelPendingDetection()
        }
    }

    private func identifyAndScheduleDetection() {
        guard isEnabled, isMonitoring else {
            return
        }

        guard !isRecordingActive() else {
            cancelPendingDetection()
            return
        }

        guard let candidate = bestDetectionCandidate() else {
            cancelPendingDetection()
            return
        }

        scheduleDetection(for: candidate)
    }

    private func bestDetectionCandidate() -> DetectionCandidate? {
        let now = Date()
        pruneCooldowns(now: now)

        let ownBundleID = Bundle.main.bundleIdentifier
        let activeProcesses = activeInputProcesses().filter { process in
            guard process.bundleID != ownBundleID else {
                return false
            }
            return !isInCooldown(bundleID: process.bundleID, now: now)
        }

        guard !activeProcesses.isEmpty else {
            return nil
        }

        let needsWindowEvaluation = activeProcesses.contains { process in
            switch process.category {
            case .meetingApp(let appName):
                return appName.caseInsensitiveCompare("Discord") != .orderedSame
            case .browser:
                return true
            }
        }

        let windows = needsWindowEvaluation ? readWindowListSnapshot() : []
        var windowsByPID: [pid_t: [WindowInfo]] = [:]
        for window in windows {
            windowsByPID[window.pid, default: []].append(window)
        }

        var candidates: [DetectionCandidate] = []
        for process in activeProcesses {
            switch process.category {
            case .meetingApp(let appName):
                let confidence: DetectionConfidence
                if process.bundleID == Self.discordBundleID {
                    confidence = .medium
                } else {
                    let confirmationWindows = windowsByPID[process.pid] ?? []
                    confidence = isMeetingWindowConfirmed(
                        bundleID: process.bundleID,
                        windows: confirmationWindows
                    ) ? .high : .medium
                }

                candidates.append(
                    DetectionCandidate(
                        pid: process.pid,
                        bundleID: process.bundleID,
                        appName: appName,
                        confidence: confidence,
                        appPriority: Self.appPriority[process.bundleID] ?? 99
                    )
                )
            case .browser:
                let confirmationWindows = windowsByPID[process.pid] ?? []
                guard isGoogleMeetWindowConfirmed(windows: confirmationWindows) else {
                    continue
                }

                candidates.append(
                    DetectionCandidate(
                        pid: process.pid,
                        bundleID: process.bundleID,
                        appName: "Google Meet",
                        confidence: .high,
                        appPriority: 5
                    )
                )
            }
        }

        return candidates.sorted(by: candidateSortComparator).first
    }

    private func scheduleDetection(for candidate: DetectionCandidate) {
        cancelPendingDetection()
        pendingDetectionBundleID = candidate.bundleID

        pendingDetectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: candidate.confidence.debounceNanoseconds)
            } catch {
                return
            }

            await MainActor.run {
                self?.fireDetectionIfStillValid(candidate: candidate)
            }
        }
    }

    private func fireDetectionIfStillValid(candidate: DetectionCandidate) {
        guard isMonitoring, isEnabled else {
            cancelPendingDetection()
            return
        }

        guard pendingDetectionBundleID == candidate.bundleID else {
            return
        }

        pendingDetectionTask = nil
        pendingDetectionBundleID = nil

        guard !isRecordingActive() else {
            return
        }

        let now = Date()
        pruneCooldowns(now: now)
        guard !isInCooldown(bundleID: candidate.bundleID, now: now) else {
            return
        }

        if let inputDeviceID = monitoredInputDeviceID,
           let isRunning = isDeviceRunningSomewhere(inputDeviceID),
           !isRunning {
            return
        }

        cooldownByBundleID[candidate.bundleID] = now
        onMeetingDetected((detectedAppName: candidate.appName, bundleID: candidate.bundleID))
    }

    private func cancelPendingDetection() {
        pendingDetectionTask?.cancel()
        pendingDetectionTask = nil
        pendingDetectionBundleID = nil
    }

    private func pruneCooldowns(now: Date) {
        cooldownByBundleID = cooldownByBundleID.filter { now.timeIntervalSince($0.value) < Self.cooldownInterval }
    }

    private func isInCooldown(bundleID: String, now: Date) -> Bool {
        guard let lastDetectionDate = cooldownByBundleID[bundleID] else {
            return false
        }
        return now.timeIntervalSince(lastDetectionDate) < Self.cooldownInterval
    }

    private func activeInputProcesses() -> [ActiveInputProcess] {
        var address = processObjectListAddress()
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            logCoreAudioError("Failed to get process object list size", status: sizeStatus)
            return []
        }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard processCount > 0 else {
            return []
        }

        var processObjectIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: processCount)
        let listStatus = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &processObjectIDs)
        guard listStatus == noErr else {
            logCoreAudioError("Failed to read process object list", status: listStatus)
            return []
        }

        var result: [ActiveInputProcess] = []
        result.reserveCapacity(processObjectIDs.count)

        for processObjectID in processObjectIDs where processObjectID != AudioObjectID(kAudioObjectUnknown) {
            guard isProcessRunningInput(processObjectID) else {
                continue
            }

            guard let pid = processPID(processObjectID),
                  let bundleID = processBundleID(processObjectID),
                  let category = category(for: bundleID) else {
                continue
            }

            result.append(ActiveInputProcess(pid: pid, bundleID: bundleID, category: category))
        }

        return result
    }

    private func isProcessRunningInput(_ processObjectID: AudioObjectID) -> Bool {
        var address = processIsRunningInputAddress()
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &isRunning)
        guard status == noErr else {
            logCoreAudioError("Failed to read process input-running state", status: status)
            return false
        }

        return isRunning == 1
    }

    private func processPID(_ processObjectID: AudioObjectID) -> pid_t? {
        var address = processPIDAddress()
        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)

        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &pid)
        guard status == noErr else {
            logCoreAudioError("Failed to read process PID", status: status)
            return nil
        }

        return pid > 0 ? pid : nil
    }

    private func processBundleID(_ processObjectID: AudioObjectID) -> String? {
        var address = processBundleIDAddress()
        var bundleIDRef: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &bundleIDRef)
        guard status == noErr else {
            logCoreAudioError("Failed to read process bundle ID", status: status)
            return nil
        }

        guard let bundleID = bundleIDRef?.takeUnretainedValue() as String? else {
            return nil
        }

        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func category(for bundleID: String) -> ProcessCategory? {
        if let appName = Self.knownMeetingApps[bundleID] {
            return .meetingApp(name: appName)
        }
        if Self.knownBrowserBundleIDs.contains(bundleID) {
            return .browser
        }
        return nil
    }

    private func readWindowListSnapshot() -> [WindowInfo] {
        guard let windowDictionaries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowDictionaries.compactMap { window in
            guard let ownerPIDValue = window[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }

            let ownerName = (window[kCGWindowOwnerName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return WindowInfo(
                pid: pid_t(ownerPIDValue.int32Value),
                ownerName: ownerName,
                title: title
            )
        }
    }

    private func isMeetingWindowConfirmed(bundleID: String, windows: [WindowInfo]) -> Bool {
        switch bundleID {
        case Self.zoomBundleID:
            return isZoomWindowConfirmed(windows)
        case Self.teamsBundleID:
            return isTeamsWindowConfirmed(windows)
        case Self.slackBundleID:
            return windows.contains { $0.title.containsCaseInsensitive("Huddle") }
        case Self.faceTimeBundleID:
            return isFaceTimeWindowConfirmed(windows)
        default:
            return false
        }
    }

    private func isZoomWindowConfirmed(_ windows: [WindowInfo]) -> Bool {
        windows.contains { window in
            if window.title.containsCaseInsensitive("Zoom Meeting") {
                return true
            }

            if window.ownerName.caseInsensitiveCompare("CptHost") == .orderedSame,
               window.title.containsCaseInsensitive("zoom") {
                return true
            }

            return false
        }
    }

    private func isTeamsWindowConfirmed(_ windows: [WindowInfo]) -> Bool {
        for window in windows {
            let title = window.title
            if title.containsCaseInsensitive("Meeting with") {
                return true
            }

            guard let separatorRange = title.range(of: "| Microsoft Teams", options: .caseInsensitive) else {
                continue
            }

            let prefix = String(title[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else {
                continue
            }

            let normalizedPrefix = prefix.lowercased()
            if Self.teamsNonMeetingTitles.contains(normalizedPrefix) {
                continue
            }

            if prefix.split(whereSeparator: \.isWhitespace).count >= 2 || prefix.count >= 8 {
                return true
            }
        }

        return false
    }

    private func isGoogleMeetWindowConfirmed(windows: [WindowInfo]) -> Bool {
        windows.contains { window in
            if window.title.containsCaseInsensitive("meet.google.com") {
                return true
            }

            let range = NSRange(window.title.startIndex..., in: window.title)
            return Self.googleMeetCodeRegex.firstMatch(in: window.title, options: [], range: range) != nil
        }
    }

    private func isFaceTimeWindowConfirmed(_ windows: [WindowInfo]) -> Bool {
        let namedFaceTimeWindows = windows.filter { window in
            window.ownerName.caseInsensitiveCompare("FaceTime") == .orderedSame
        }
        if !namedFaceTimeWindows.isEmpty {
            return namedFaceTimeWindows.count > 1
        }

        return windows.count > 1
    }

    private func candidateSortComparator(lhs: DetectionCandidate, rhs: DetectionCandidate) -> Bool {
        if lhs.confidence.priority != rhs.confidence.priority {
            return lhs.confidence.priority > rhs.confidence.priority
        }
        if lhs.appPriority != rhs.appPriority {
            return lhs.appPriority < rhs.appPriority
        }
        return lhs.pid < rhs.pid
    }

    private func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var address = defaultInputDeviceAddress()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else {
            logCoreAudioError("Failed to read default input device", status: status)
            return nil
        }

        return deviceID == AudioDeviceID(kAudioObjectUnknown) ? nil : deviceID
    }

    private func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool? {
        var address = deviceIsRunningAddress()
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var isRunning: UInt32 = 0

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isRunning)
        guard status == noErr else {
            logCoreAudioError("Failed to read input-device running state", status: status)
            return nil
        }

        return isRunning == 1
    }

    private func defaultInputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func deviceIsRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func processObjectListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func processIsRunningInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func processPIDAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func processBundleIDAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func logCoreAudioError(_ message: String, status: OSStatus) {
        NSLog("MeetingRecorder: \(message). OSStatus=\(status)")
    }
}

private extension String {
    func containsCaseInsensitive(_ string: String) -> Bool {
        range(of: string, options: .caseInsensitive) != nil
    }
}
