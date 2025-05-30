import NodeAPI

enum PASEvent {
    /// A PAS event with type `toast`.
    ///
    /// Displays user-visible text in a dismissible notification.
    case toast(message: String, id: String?, timeoutMilliseconds: Int?)
    /// A PAS event with type `thread_messages_refresh`.
    case refreshMessagesInThread(id: String)
    /// A PAS event with type `state_sync` that is used to `update` a
    /// `thread`.
    case stateSyncThread(id: String, properties: NodeObjectPropertyList)
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
        case let .stateSyncThread(id, properties):
            let entry = try NodeObject(["id": id])
            try entry.define(properties)

            return try NodeObject([
                "type": "state_sync",
                "objectIDs": ["threadID": null, "messageID": null],
                "objectName": "thread",
                "mutationType": "update",
                "entries": [entry].nodeValue()
            ])
        }
    }
}
