/** Represents a row in the `chat` table. */
public struct Chat {
    public var id: Int
    public var guid: String

    /** The name of this chat, if it's a group. */
    public var displayName: String?
}
