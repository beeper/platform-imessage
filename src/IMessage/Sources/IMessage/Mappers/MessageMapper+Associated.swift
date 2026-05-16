import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

extension Mapper {
    func footer() -> MessagePatch {
        let expressiveSendStyleID = msgRow.expressiveSendStyleID ?? ""
        if let effect = expressiveMessages[expressiveSendStyleID] {
            return MessagePatch(textFooter: "(Sent with \(effect) effect)")
        }
        if let service = msgRow.service, let footer = serviceFooters[service] {
            return MessagePatch(textFooter: footer)
        }
        return MessagePatch()
    }

    func associatedMessage(
        messages: inout [MessageDraft],
        partialMessage: MessageDraft,
        summaryInfo: JSONObject,
        isSMS: Bool,
        associatedTarget: AssociatedMessageTarget
    ) -> MessageDraft? {
        let firstTextPart = messages.first { $0.text != nil }
        var message = firstTextPart ?? messages.first ?? partialMessage
        let linkedMessageID = associatedTarget.messageID
        message.linkedMessageID = linkedMessageID
        guard let associatedMessageType = associatedMessageTypes[msgRow.associatedMessageType] else {
            return nil
        }

        switch associatedMessageType {
        case .extensionUpdate:
            return message
        case .sticker:
            if !messages.isEmpty {
                messages[0].linkedMessageID = linkedMessageID
            }
            return nil
        case .pollVote:
            return actionMessage(
                message,
                text: actionText("voted in a poll"),
                isHidden: true
            )
        case .heading:
            if msgRow.balloonBundleID == BalloonBundleID.polls {
                return actionMessage(message, text: actionText("sent a poll"))
            }
            if var text = message.text {
                let other = msgRow.participantID ?? ""
                let isSender = message.isSender == true
                let senderName = isSender ? currentUserID : other
                let receiverName = isSender ? other : currentUserID
                text = text
                    .replacingOccurrences(of: receiverNamePlaceholder, with: "{{\(receiverName)}}")
                    .replacingOccurrences(of: senderNamePlaceholder, with: "{{\(senderName)}}")
                message.text = text
            }
            message.parseTemplate = true
            return message
        case let .reaction(reaction):
            return mapReactionAction(
                reaction: reaction,
                message: message,
                summaryInfo: summaryInfo,
                isSMS: isSMS
            )
        }
    }

    func assignReactions(to message: inout MessageDraft, filterIndex: Int?) {
        var reactions = [PlatformSDK.MessageReaction]()
        let filteredRows = reactionRows.filter { reaction in
            guard let filterIndex else {
                return true
            }
            return reaction.associatedMessageGUID.hasPrefix("p:\(filterIndex)/")
        }
        for reaction in filteredRows {
            guard let associatedMessageType = associatedMessageTypes[reaction.associatedMessageType],
                  case let .reaction(parts) = associatedMessageType else {
                continue
            }
            let participantID = messageSenderID(for: reaction, currentUserID: currentUserID)
            if parts.action == .reacted {
                reactions.append(mapMessageReaction(row: reaction, reaction: parts, currentUserID: currentUserID, accountID: accountID))
            } else if parts.action == .unreacted, let index = reactions.firstIndex(where: { $0.participantID == participantID }) {
                reactions.remove(at: index)
            }
        }
        if !reactions.isEmpty {
            message.reactions = reactions
        }
    }

    func subject() -> String? {
        guard let subject = msgRow.subject, !subject.isEmpty else {
            return nil
        }
        return subject
    }

    private func mapReactionAction(
        reaction: AssociatedReaction,
        message inputMessage: MessageDraft,
        summaryInfo: JSONObject,
        isSMS: Bool
    ) -> MessageDraft {
        var message = inputMessage
        message.isAction = !isSMS
        let action = PlatformSDK.PartialMessageReactionAction(
            messageID: message.linkedMessageID,
            reactionKey: reaction.platformReactionKey(emoji: msgRow.associatedMessageEmoji),
            imgURL: reaction.isSticker ? reactionStickerAssetURL(accountID: accountID, rowID: msgRow.rowID) : nil,
            participantID: message.senderID
        )
        message.action = reaction.action == .reacted
            ? .messageReactionCreated(action)
            : .messageReactionDeleted(action)
        message.parseTemplate = true
        let actor = msgRow.isFromMe == 1 ? "You" : "{{sender}}"
        let target = summaryInfo.string("ams").flatMap { $0.isEmpty ? nil : $0 }.map { "\"\($0)\"" } ?? "a message"
        message.text = "\(actor) \(reaction.verb) \(target)"
        message.isHidden = true
        return message
    }
}

protocol RowWithSenderFields {
    var isFromMe: Int { get }
    var handleID: Int? { get }
    var participantID: String? { get }
}

protocol MessageReactionRowFields: RowWithSenderFields {
    var rowID: Int { get }
    var associatedMessageType: Int { get }
    var associatedMessageEmoji: String? { get }
}

extension MappedMessageRow: RowWithSenderFields {}
extension MappedReactionMessageRow: RowWithSenderFields {}
extension MappedMessageRow: MessageReactionRowFields {}
extension MappedReactionMessageRow: MessageReactionRowFields {}

func messageSenderID(for row: any RowWithSenderFields, currentUserID: String) -> String {
    if row.isFromMe == 1 || ((row.participantID ?? "").isEmpty && row.handleID == 0) {
        return currentUserID
    }
    return row.participantID ?? ""
}

func messageReactionID(participantID: PlatformSDK.UserID, reactionKey: String) -> PlatformSDK.ID {
    "\(participantID)\(reactionKey)"
}

private func reactionStickerAssetURL(accountID: String, rowID: Int) -> String {
    "asset://\(accountID)/reaction-sticker/\(rowID).heic"
}

func mapMessageReaction(
    row: any MessageReactionRowFields,
    reaction: AssociatedReaction,
    currentUserID: String,
    accountID: String
) -> PlatformSDK.MessageReaction {
    let reactionKey = reaction.platformReactionKey(emoji: row.associatedMessageEmoji) ?? ""
    let participantID = messageSenderID(for: row, currentUserID: currentUserID)
    return PlatformSDK.MessageReaction(
        id: messageReactionID(participantID: participantID, reactionKey: reactionKey),
        reactionKey: reactionKey,
        imgURL: reaction.isSticker ? reactionStickerAssetURL(accountID: accountID, rowID: row.rowID) : nil,
        participantID: participantID
    )
}
