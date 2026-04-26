import Foundation

public enum PASEvent {
    /// A PAS event with type `toast`.
    ///
    /// Displays user-visible text in a dismissible notification.
    case toast(message: String, id: String?, timeoutMilliseconds: Int?)
    /// A PAS event with type `thread_messages_refresh`.
    case refreshMessagesInThread(id: String)
    /// A PAS event with type `state_sync` that is used to `update` a
    /// `thread`.
    case stateSyncThread(id: String, patch: JSONObject)
    /// A PAS event with type `state_sync` that is used to `delete`
    /// one or more threads.
    case deleteThreads(ids: [String])
}

extension PASEvent {
    public func jsonObject() -> JSONObject {
        switch self {
        case let .toast(message, id, timeout):
            return [
                "id": id ?? NSNull(),
                "text": message,
                "timeoutMs": timeout ?? NSNull(),
            ]
        case let .refreshMessagesInThread(id):
            return [
                "type": "thread_messages_refresh",
                "threadID": id,
            ]
        case let .stateSyncThread(id, patch):
            var entry = JSONObject()
            for (key, value) in patch {
                entry[key] = jsonObjectValue(value)
            }
            entry["id"] = id

            return [
                "type": "state_sync",
                "objectIDs": ["threadID": NSNull(), "messageID": NSNull()],
                "objectName": "thread",
                "mutationType": "update",
                "entries": [entry],
            ]
        case let .deleteThreads(ids):
            return [
                "type": "state_sync",
                "objectIDs": ["threadID": NSNull(), "messageID": NSNull()],
                "objectName": "thread",
                "mutationType": "delete",
                "entries": ids,
            ]
        }
    }

    private func jsonObjectValue(_ value: Any) -> Any {
        switch value {
        case is String, is Bool, is Int, is Double, is Float, is NSNull:
            return value
        default:
            return String(describing: value)
        }
    }
}
