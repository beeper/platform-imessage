import Foundation

extension PlatformSDK {
    public enum MessageActionType: String {
        case threadTitleUpdated = "thread_title_updated"
        case threadParticipantsAdded = "thread_participants_added"
        case threadParticipantsRemoved = "thread_participants_removed"
        case groupThreadCreated = "group_thread_created"
        case threadImgChanged = "thread_img_changed"
        case messageRequestAccepted = "message_request_accepted"
        case messageReactionCreated = "message_reaction_created"
        case messageReactionDeleted = "message_reaction_deleted"
    }

    public enum MessageAction: JSONObjectConvertible {
        case threadTitleUpdated(title: String?, actorParticipantID: UserID)
        case threadParticipantsAdded(participantIDs: [UserID], actorParticipantID: UserID, participants: [Participant]?)
        case threadParticipantsRemoved(participantIDs: [UserID], actorParticipantID: UserID, participants: [Participant]?)
        case groupThreadCreated(title: String, actorParticipantID: UserID)
        case threadImgChanged(actorParticipantID: UserID)
        case messageRequestAccepted
        case messageReactionCreated(PartialMessageReactionAction)
        case messageReactionDeleted(PartialMessageReactionAction)

        public var jsonObject: JSONObject {
            switch self {
            case let .threadTitleUpdated(title, actorParticipantID):
                return [
                    "type": MessageActionType.threadTitleUpdated.rawValue,
                    "title": title as Any? ?? NSNull(),
                    "actorParticipantID": actorParticipantID,
                ]
            case let .threadParticipantsAdded(participantIDs, actorParticipantID, participants):
                return compactDictionary([
                    "type": MessageActionType.threadParticipantsAdded.rawValue,
                    "participantIDs": participantIDs,
                    "actorParticipantID": actorParticipantID,
                    "participants": participants?.map(\.jsonObject),
                ])
            case let .threadParticipantsRemoved(participantIDs, actorParticipantID, participants):
                return compactDictionary([
                    "type": MessageActionType.threadParticipantsRemoved.rawValue,
                    "participantIDs": participantIDs,
                    "actorParticipantID": actorParticipantID,
                    "participants": participants?.map(\.jsonObject),
                ])
            case let .groupThreadCreated(title, actorParticipantID):
                return [
                    "type": MessageActionType.groupThreadCreated.rawValue,
                    "title": title,
                    "actorParticipantID": actorParticipantID,
                ]
            case let .threadImgChanged(actorParticipantID):
                return [
                    "type": MessageActionType.threadImgChanged.rawValue,
                    "actorParticipantID": actorParticipantID,
                ]
            case .messageRequestAccepted:
                return ["type": MessageActionType.messageRequestAccepted.rawValue]
            case let .messageReactionCreated(reaction):
                var object = reaction.jsonObject
                object["type"] = MessageActionType.messageReactionCreated.rawValue
                return object
            case let .messageReactionDeleted(reaction):
                var object = reaction.jsonObject
                object["type"] = MessageActionType.messageReactionDeleted.rawValue
                return object
            }
        }
    }

    @PlatformSDKJSONObject
    public struct PartialMessageReactionAction: JSONObjectConvertible {
        public let messageID: MessageID?
        public let id: ID?
        public let reactionKey: String?
        public let imgURL: String?
        public let participantID: UserID?
        public let emoji: Bool?

    }
}
