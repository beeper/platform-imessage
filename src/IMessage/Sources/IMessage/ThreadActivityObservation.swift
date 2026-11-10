import Foundation
import PlatformSDK

// Reserve requests under the selection lock before resolving their database identity.
struct SelectedThreadActivitySelection {
    struct Thread: Sendable {
        let requestID: UUID
        let threadID: String
        let sendStatus: @Sendable (ThreadActivityObservation) async -> Void
    }

    private(set) var requestID = UUID()
    private var owner: ObjectIdentifier?
    private(set) var thread: Thread?

    mutating func begin(owner: ObjectIdentifier) -> UUID {
        requestID = UUID()
        self.owner = owner
        thread = nil
        return requestID
    }

    mutating func install(_ thread: Thread) -> Bool {
        guard requestID == thread.requestID else { return false }
        self.thread = thread
        return true
    }

    mutating func clear(ifCurrent requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.requestID = UUID()
        thread = nil
        owner = nil
    }

    mutating func clear(ifOwnedBy owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        clear(ifCurrent: requestID)
    }
}

struct ThreadActivityObservationCache {
    private var requestID: UUID?
    private var observation: ThreadActivityObservation?
    private var sentAt: Date?

    mutating func shouldSend(_ observation: ThreadActivityObservation, requestID: UUID, now: Date = Date()) -> Bool {
        guard self.requestID != requestID || self.observation != observation ||
                (observation.activityType == .typing && sentAt.map { now.timeIntervalSince($0) > 30 } == true) else {
            return false
        }
        self.requestID = requestID
        self.observation = observation
        sentAt = now
        return true
    }
}

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
