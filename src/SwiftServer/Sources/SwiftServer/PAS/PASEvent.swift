import NodeAPI

enum PASEvent {
    /// A PAS event with type `toast`.
    ///
    /// Displays user-visible text in a dismissible notification.
    case toast(message: String, id: String?, timeoutMilliseconds: Int?)
    /// A PAS event with type `thread_messages_refresh`.
    case refreshMessagesInThread(id: String)
    /// A PAS event with type `state_sync` that is used to `delete`
    /// one or more messages from a single thread.
    case deleteMessages(threadID: String, ids: [String])
    /// A PAS event with type `state_sync` that is used to `update` a
    /// `thread`.
    case stateSyncThread(id: String, patch: [String: any NodePropertyConvertible])
    /// A PAS event with type `state_sync` that is used to `delete`
    /// one or more threads.
    case deleteThreads(ids: [String])
}

extension PASEvent: NodeValueConvertible {
    func nodeValue() throws -> any NodeValue {
        switch self {
        case let .toast(message, id, timeout): return try NodeObject([
            "id": id,
            "text": message,
            "timeoutMs": timeout
        ])
        case let .refreshMessagesInThread(id): return try NodeObject([
            "type": "thread_messages_refresh",
            "threadID": id,
        ])
        case let .deleteMessages(threadID, ids):
            return try NodeObject([
                "type": "state_sync",
                "objectIDs": ["threadID": threadID, "messageID": null],
                "objectName": "message",
                "mutationType": "delete",
                "entries": (ids as [NodeValueConvertible]).nodeValue()
            ])
        case let .stateSyncThread(id, patch):
            let entry = try NodeObject(coercing: patch)
            try entry.define(["id": id])

            return try NodeObject([
                "type": "state_sync",
                "objectIDs": ["threadID": null, "messageID": null],
                "objectName": "thread",
                "mutationType": "update",
                "entries": [entry].nodeValue()
            ])
        case let .deleteThreads(ids):
            return try NodeObject([
                "type": "state_sync",
                "objectIDs": ["threadID": null, "messageID": null],
                "objectName": "thread",
                "mutationType": "delete",
                "entries": (ids as [NodeValueConvertible]).nodeValue()
            ])
        }
    }
}
