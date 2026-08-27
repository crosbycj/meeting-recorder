enum MeetingEndNotification {
    static let categoryIdentifier = "MEETING_ENDED"
    static let resumeActionIdentifier = "RESUME_RECORDING"
    static let requestIdentifier = "meeting-ended"
}

enum MeetingDetectedNotification {
    static let categoryIdentifier = "MEETING_DETECTED"
    static let startRecordingActionIdentifier = "START_RECORDING"
    static let requestIdentifier = "meeting-detected"

    private enum UserInfoKey {
        static let bundleID = "bundleID"
        static let appName = "appName"
    }

    static func userInfo(bundleID: String, appName: String) -> [String: Any] {
        [
            UserInfoKey.bundleID: bundleID,
            UserInfoKey.appName: appName
        ]
    }

    static func bundleID(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[UserInfoKey.bundleID] as? String
    }

    static func appName(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[UserInfoKey.appName] as? String
    }
}
