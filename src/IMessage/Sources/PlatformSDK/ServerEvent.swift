import Foundation

extension PlatformSDK {
    public enum ServerEventType: String {
        case stateSync = "state_sync"
        case toast
        case threadMessagesRefresh = "thread_messages_refresh"
        case userActivity = "user_activity"
        case userPresenceUpdated = "user_presence_updated"
        case sessionUpdated = "session_updated"
        case refreshAccount = "refresh_account"
    }
}

public enum ServerEvent {
    /// A server event with type `user_activity`.
    case userActivity(
        activityType: PlatformSDK.ActivityType,
        threadID: PlatformSDK.ThreadID,
        participantID: PlatformSDK.UserID,
        durationMilliseconds: Int?,
        customLabel: String?
    )
    /// A server event with type `user_presence_updated`.
    case userPresenceUpdated(PlatformSDK.UserPresence)
    /// A server event with type `toast`.
    ///
    /// Displays user-visible text in a dismissible notification.
    case toast(message: String, id: String?, timeoutMilliseconds: Int?)
    /// A server event with type `thread_messages_refresh`.
    case refreshMessagesInThread(id: PlatformSDK.ThreadID)
    /// A server event with type `state_sync` that is used to `update` a
    /// `thread`.
    case stateSyncThread(id: PlatformSDK.ThreadID, patch: JSONObject)
    /// A server event with type `state_sync` that is used to `delete`
    /// one or more threads.
    case deleteThreads(ids: [PlatformSDK.ThreadID])
}

extension ServerEvent {
    public func jsonObject() -> JSONObject {
        switch self {
        case let .userActivity(activityType, threadID, participantID, durationMilliseconds, customLabel):
            return compactDictionary([
                "type": PlatformSDK.ServerEventType.userActivity.rawValue,
                "activityType": activityType.rawValue,
                "threadID": threadID,
                "participantID": participantID,
                "durationMs": durationMilliseconds,
                "customLabel": customLabel,
            ])
        case let .userPresenceUpdated(presence):
            return [
                "type": PlatformSDK.ServerEventType.userPresenceUpdated.rawValue,
                "presence": presence.jsonObject,
            ]
        case let .toast(message, id, timeout):
            return [
                "type": PlatformSDK.ServerEventType.toast.rawValue,
                "toast": compactDictionary([
                    "id": id,
                    "text": message,
                    "timeoutMs": timeout,
                ]),
            ]
        case let .refreshMessagesInThread(id):
            return [
                "type": PlatformSDK.ServerEventType.threadMessagesRefresh.rawValue,
                "threadID": id,
            ]
        case let .stateSyncThread(id, patch):
            var entry = JSONObject()
            for (key, value) in patch {
                entry[key] = jsonObjectValue(value)
            }
            entry["id"] = id

            return [
                "type": PlatformSDK.ServerEventType.stateSync.rawValue,
                "objectIDs": ["threadID": NSNull(), "messageID": NSNull()],
                "objectName": "thread",
                "mutationType": "update",
                "entries": [entry],
            ]
        case let .deleteThreads(ids):
            return [
                "type": PlatformSDK.ServerEventType.stateSync.rawValue,
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
