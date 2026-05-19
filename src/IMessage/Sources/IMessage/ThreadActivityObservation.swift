import PlatformSDK

public struct ThreadActivityObservation: PlatformSDK.JSONObjectConvertible, Equatable, Sendable, CustomStringConvertible {
    public let activityType: PlatformSDK.ActivityType
    public let presenceStatus: PlatformSDK.UserPresenceStatus?
    public let didObservePresence: Bool

    public static let unknown = ThreadActivityObservation(
        activityType: .none,
        presenceStatus: nil,
        didObservePresence: false
    )

    public init(
        activityType: PlatformSDK.ActivityType,
        presenceStatus: PlatformSDK.UserPresenceStatus?,
        didObservePresence: Bool
    ) {
        self.activityType = activityType
        self.presenceStatus = presenceStatus
        self.didObservePresence = didObservePresence
    }

    public var description: String {
        var parts = ["activityType=\(activityType.rawValue)"]
        if let presenceStatus {
            parts.append("presenceStatus=\(presenceStatus.rawValue)")
        } else if !didObservePresence {
            parts.append("presenceStatus=unknown")
        }
        return parts.joined(separator: ",")
    }

    public var jsonObject: JSONObject {
        var object: JSONObject = [
            "activityType": activityType.rawValue,
            "didObservePresence": didObservePresence,
        ]
        if let presenceStatus {
            object["presenceStatus"] = presenceStatus.rawValue
        } else if !didObservePresence {
            object["presenceStatus"] = "unknown"
        }
        return object
    }
}
