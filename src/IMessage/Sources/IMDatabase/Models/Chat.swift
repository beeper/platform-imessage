/** Represents a row in the `chat` table. */
public struct Chat {
    public var id: Int
    public var guid: GUID<Chat>

    /** For group chats, a custom name. For business chats, the business name. */
    public var displayName: String?
    public var serviceName: ServiceName
}

public extension Chat {
    /** `service_name` column of `chat` rows. */
    struct ServiceName: RawRepresentable, Hashable, Equatable, Sendable {
        public var rawValue: String

        public static let rcs = Self(rawValue: "RCS")
        public static let sms = Self(rawValue: "SMS")
        public static let imessage = Self(rawValue: "iMessage")

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

// RCS might not be a thing, but just in case
private let businessGUIDPrefixes = ["SMS;-;urn:biz:", "iMessage;-;urn:biz:", "RCS;-;urn:biz:", "any;-;urn:biz:"]

public extension Chat {
    var isBusiness: Bool {
        businessGUIDPrefixes.contains(where: { guid.guts.hasPrefix($0) })
    }
}
