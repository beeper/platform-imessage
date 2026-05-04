import Foundation

extension PlatformSDK {
    public enum ServerEventType: String {
        case stateSync = "state_sync"
        case toast
        @available(*, deprecated, message: "Use state_sync message events instead.")
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
    @available(*, deprecated, message: "Use state_sync message events instead.")
    case refreshMessagesInThread(id: PlatformSDK.ThreadID)
    /// A server event with type `state_sync` that is used to `update` a
    /// `thread`.
    case stateSyncThread(id: PlatformSDK.ThreadID, patch: JSONObject)
    /// A server event with type `state_sync` that is used to `delete`
    /// one or more threads.
    case deleteThreads(ids: [PlatformSDK.ThreadID])
    /// A server event with type `state_sync` that is used to `upsert`
    /// messages in a thread.
    case upsertMessages(threadID: PlatformSDK.ThreadID, messages: [PlatformSDK.Message])
    /// A server event with type `state_sync` that is used to `update`
    /// messages in a thread.
    case updateMessages(threadID: PlatformSDK.ThreadID, patches: [JSONObject])
    /// A server event with type `state_sync` that is used to `delete`
    /// messages in a thread.
    case deleteMessages(threadID: PlatformSDK.ThreadID, ids: [PlatformSDK.MessageID])
    /// A server event with type `state_sync` that is used to `upsert`
    /// reactions for a message.
    case upsertMessageReactions(threadID: PlatformSDK.ThreadID, messageID: PlatformSDK.MessageID, reactions: [PlatformSDK.MessageReaction])
    /// A server event with type `state_sync` that is used to `delete`
    /// reactions for a message.
    case deleteMessageReactions(threadID: PlatformSDK.ThreadID, messageID: PlatformSDK.MessageID, ids: [PlatformSDK.ID])
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
                "type": PlatformSDK.ServerEventType.stateSync.rawValue,
                "objectIDs": JSONObject(),
                "objectName": "thread",
                "mutationType": "update",
                "entries": [entry],
            ]
        case let .deleteThreads(ids):
            return [
                "type": PlatformSDK.ServerEventType.stateSync.rawValue,
                "objectIDs": JSONObject(),
                "objectName": "thread",
                "mutationType": "delete",
                "entries": ids,
            ]
        case let .upsertMessages(threadID, messages):
            return messageStateSyncJSON(
                threadID: threadID,
                mutationType: "upsert",
                entries: messages.map(\.jsonObject)
            )
        case let .updateMessages(threadID, patches):
            return messageStateSyncJSON(
                threadID: threadID,
                mutationType: "update",
                entries: patches
            )
        case let .deleteMessages(threadID, ids):
            return messageStateSyncJSON(
                threadID: threadID,
                mutationType: "delete",
                entries: ids
            )
        case let .upsertMessageReactions(threadID, messageID, reactions):
            return messageReactionStateSyncJSON(
                threadID: threadID,
                messageID: messageID,
                mutationType: "upsert",
                entries: reactions.map(\.jsonObject)
            )
        case let .deleteMessageReactions(threadID, messageID, ids):
            return messageReactionStateSyncJSON(
                threadID: threadID,
                messageID: messageID,
                mutationType: "delete",
                entries: ids
            )
        }
    }

    private func messageStateSyncJSON(threadID: PlatformSDK.ThreadID, mutationType: String, entries: Any) -> JSONObject {
        [
            "type": PlatformSDK.ServerEventType.stateSync.rawValue,
            "objectIDs": ["threadID": threadID],
            "objectName": "message",
            "mutationType": mutationType,
            "entries": entries,
        ]
    }

    private func messageReactionStateSyncJSON(threadID: PlatformSDK.ThreadID, messageID: PlatformSDK.MessageID, mutationType: String, entries: Any) -> JSONObject {
        [
            "type": PlatformSDK.ServerEventType.stateSync.rawValue,
            "objectIDs": [
                "threadID": threadID,
                "messageID": messageID,
            ],
            "objectName": "message_reaction",
            "mutationType": mutationType,
            "entries": entries,
        ]
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
