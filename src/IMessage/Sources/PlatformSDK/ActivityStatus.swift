extension PlatformSDK {
    public enum ActivityType: String, Sendable {
        case none
        case online
        case offline
        case typing
        case custom
        case recordingVoice = "recording_voice"
        case recordingVideo = "recording_video"
    }

    public enum UserPresenceStatus: String, Sendable {
        case online
        case offline
        case dnd
        case dndCanNotify = "dnd_can_notify"
        case idle
        case invisible
        case custom
    }

    public enum AppState: String, Sendable {
        case suspending
        case resuming
    }

    @PlatformSDKJSONObject
    public struct UserPresence: JSONObjectConvertible {
        public let userID: UserID
        public let status: UserPresenceStatus
        public let customStatus: String?
        public let lastActive: Timestamp?
        public let durationMs: Int?
    }
}
