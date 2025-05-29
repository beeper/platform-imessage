/// Either a `ROWID` to an iMessage chat, its `guid` column (e.g. `iMessage;-;+17075551234`),
/// or both.
///
/// This type shouldn't be used for identification and is solely a convenience
/// type vended by methods that return query results.
public enum ChatRef {
    case justRowID(Int)
    case justGUID(String)
    case both(rowID: Int, guid: String)
}

extension ChatRef {
    public var rowID: Int? {
        switch self {
        case let .justRowID(rowID): rowID
        case let .both(rowID, _): rowID
        default: nil
        }
    }

    public var guid: String? {
        switch self {
        case let .justGUID(guid): guid
        case let .both(_, guid): guid
        default: nil
        }
    }
}

extension ChatRef: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .justRowID(rowID): hasher.combine(rowID)
        case let .both(rowID, _): hasher.combine(rowID)
        case let .justGUID(guid): hasher.combine(guid)
        }
    }
}
