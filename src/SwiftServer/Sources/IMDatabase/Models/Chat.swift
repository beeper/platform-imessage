/** Represents a row in the `chat` table. */
public struct Chat {
    public var id: Int
    public var guid: GUID<Chat>

    /** For group chats, a custom name. For business chats, the business name. */
    public var displayName: String?
    public var serviceName: ServiceName

    // MARK: - Filtering

    /// Bitmask from `is_filtered` column indicating message category.
    public var filterCategory: FilterCategory

    /// Whether the chat is pending review (unknown sender needing verification).
    public var isPendingReview: Bool

    /// Parsed properties blob containing detailed SMS categorization.
    public var properties: Properties?
}

public extension Chat {
    /** `service_name` column of `chat` rows. */
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
        businessGUIDPrefixes.contains(where: { guid.guts.hasPrefix($0) })
    }
}
