import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol MeetingSignalProvider {
    /// Human-readable name for logging
    var name: String { get }
    /// Returns true if this provider detects an active meeting right now
    func isMeetingActive() -> Bool
}

@MainActor
final class ZoomProcessSignalProvider: MeetingSignalProvider {
    private static let meetingKeyRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)-key\s+([0-9]{9,10})(?:\s|$)"#
    )

    let name = "ZoomProcessSignalProvider"

    func isMeetingActive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-ax", "CptHost"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        guard waitForProcessToExit(process, timeout: 1.0) else {
            if process.isRunning {
                process.terminate()
            }
            return false
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty,
              let output = String(data: outputData, encoding: .utf8) else {
            return false
        }

        for line in output.split(separator: "\n") {
            let lineString = String(line)
            let range = NSRange(lineString.startIndex..., in: lineString)
            if Self.meetingKeyRegex.firstMatch(in: lineString, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    private func waitForProcessToExit(_ process: Process, timeout: TimeInterval) -> Bool {
        guard process.isRunning else {
            return true
        }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while waitGroup.wait(timeout: .now()) == .timedOut {
            if Date() >= deadline {
                return false
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        return true
    }
}

@MainActor
final class WindowTitleSignalProvider: MeetingSignalProvider {
    private static let targetBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome"
    ]

    private static let googleMeetCodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\bMeet - [a-z]+-[a-z]+-[a-z]+\b"#
    )

    private static let zoomTopicRegex = try! NSRegularExpression(
        pattern: #"(?i)^(?!zoom workplace$)(?!zoom$)(?!home$)(?!meetings?$)(?!team chat$)(?!contacts$)(?!mail$)(?!calendar$)(?!whiteboards$)(?!docs$).{6,}$"#
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

    private static let teamsMeetingKeywords = [
        "meeting",
        "standup",
        "sync",
        "review",
        "retro",
        "call",
        "interview"
    ]

    let name = "WindowTitleSignalProvider"

    func isMeetingActive() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            // Screen Recording permission can be revoked while the app is running.
            return false
        }

        var bundleIDByPID: [pid_t: String] = [:]

        for window in windowList {
            guard let ownerPIDNumber = window[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let pid = pid_t(ownerPIDNumber.int32Value)

            guard let bundleID = bundleIDForProcess(pid, cache: &bundleIDByPID),
                  Self.targetBundleIDs.contains(bundleID) else {
                continue
            }

            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            switch bundleID {
            case "us.zoom.xos":
                if isZoomMeetingWindow(title: title, ownerName: ownerName) {
                    return true
                }
            case "com.microsoft.teams", "com.microsoft.teams2":
                if isTeamsMeetingWindow(title: title) {
                    return true
                }
            case "com.google.Chrome":
                if isGoogleMeetWindow(title: title) {
                    return true
                }
            default:
                continue
            }
        }

        return false
    }

    private func bundleIDForProcess(_ pid: pid_t, cache: inout [pid_t: String]) -> String? {
        if let cached = cache[pid] {
            return cached
        }

        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return nil
        }

        cache[pid] = bundleID
        return bundleID
    }

    private func isZoomMeetingWindow(title: String, ownerName: String) -> Bool {
        if title.containsCaseInsensitive("Zoom Meeting") {
            return true
        }

        guard ownerName.caseInsensitiveCompare("zoom.us") == .orderedSame else {
            return false
        }

        guard !title.containsCaseInsensitive("Zoom Workplace") else {
            return false
        }

        let range = NSRange(title.startIndex..., in: title)
        return Self.zoomTopicRegex.firstMatch(in: title, options: [], range: range) != nil
    }

    private func isTeamsMeetingWindow(title: String) -> Bool {
        if title.range(of: #"^Meeting with "#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        guard let separatorRange = title.range(of: " | Microsoft Teams", options: .caseInsensitive) else {
            return false
        }

        let subject = String(title[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            return false
        }

        let normalizedSubject = subject.lowercased()
        if Self.teamsNonMeetingTitles.contains(normalizedSubject) {
            return false
        }

        if Self.teamsMeetingKeywords.contains(where: { normalizedSubject.contains($0) }) {
            return true
        }

        return subject.split(whereSeparator: \.isWhitespace).count >= 2
    }

    private func isGoogleMeetWindow(title: String) -> Bool {
        if title.containsCaseInsensitive("Google Meet") {
            return true
        }

        let range = NSRange(title.startIndex..., in: title)
        return Self.googleMeetCodeRegex.firstMatch(in: title, options: [], range: range) != nil
    }
}

private extension String {
    func containsCaseInsensitive(_ substring: String) -> Bool {
        range(of: substring, options: .caseInsensitive) != nil
    }
}
