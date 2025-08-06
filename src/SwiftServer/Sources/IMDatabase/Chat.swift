/** Represents a row in the `chat` table. */
public struct Chat {
    public var id: Int
    public var guid: String

    /** For group chats, a custom name. For business chats, the business name. */
    public var displayName: String?
}

private var businessGUIDPrefixes: [String] {
    // RCS might not be a thing, but just in case
    ["SMS;-;urn:biz:", "iMessage;-;urn:biz:", "RCS;-;urn:biz:"]
}

public extension Chat {
    var isBusiness: Bool {
        businessGUIDPrefixes.contains(where: { guid.hasPrefix($0) })
    }
}
