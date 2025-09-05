/** Represents a row in the `chat` table. */
public struct Chat {
    public var id: Int
    public var guid: String

    /** For group chats, a custom name. For business chats, the business name. */
    public var displayName: String?
    public var serviceName: ServiceName
}

public extension Chat {
    struct ServiceName: RawRepresentable, Hashable, Equatable, Sendable {
        public var rawValue: String
        
        public static var rcs: Self { Self(rawValue: "RCS") }
        public static var sms: Self { Self(rawValue: "SMS") }
        public static var imessage: Self { Self(rawValue: "iMessage") }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

private var businessGUIDPrefixes: [String] {
    // RCS might not be a thing, but just in case
    ["SMS;-;urn:biz:", "iMessage;-;urn:biz:", "RCS;-;urn:biz:", "any;-;urn:biz:"]
}

public extension Chat {
    var isBusiness: Bool {
        businessGUIDPrefixes.contains(where: { guid.hasPrefix($0) })
    }
}
