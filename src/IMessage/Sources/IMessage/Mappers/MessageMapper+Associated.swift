import Foundation
import IMDatabase

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
        associatedGUID: String
    ) -> MessageDraft? {
        let firstTextPart = messages.first { $0.text != nil }
        var message = firstTextPart ?? partialMessage
        let guidRange = NSRange(associatedGUID.startIndex ..< associatedGUID.endIndex, in: associatedGUID)
        let linkedMessageID = assocMsgGUIDPrefixRegex.stringByReplacingMatches(
            in: associatedGUID,
            range: guidRange,
            withTemplate: ""
        )
        message.linkedMessageID = linkedMessageID
        guard let assocMsgType = associatedMessageTypes[msgRow.associatedMessageType] else {
            return nil
        }

        switch assocMsgType {
        case "sticker":
            if !messages.isEmpty {
                messages[0].linkedMessageID = linkedMessageID
            }
            return nil
        case "heading":
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
        default:
            return mapReactionAction(
                assocMsgType: assocMsgType,
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
            guard let assocMsgType = associatedMessageTypes[reaction.associatedMessageType],
                  let parts = reactionParts(assocMsgType),
                  assocMsgType != "sticker" else {
                continue
            }
            let participantID = senderID(for: reaction)
            if parts.actionType == "reacted" {
                reactions.append(PlatformSDK.MessageReaction(
                    id: participantID,
                    reactionKey: parts.actionKey == "emoji" ? (reaction.associatedMessageEmoji ?? "") : parts.actionKey,
                    imgURL: parts.actionKey == "sticker" ? reactionStickerAssetURL(rowID: reaction.rowID) : nil,
                    participantID: participantID
                ))
            } else if parts.actionType == "unreacted", let index = reactions.firstIndex(where: { $0.id == participantID }) {
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

    func senderID() -> String {
        senderID(for: msgRow)
    }

    func reactionStickerAssetURL(rowID: Int) -> String {
        "asset://\(accountID)/reaction-sticker/\(rowID).heic"
    }

    private func mapReactionAction(
        assocMsgType: String,
        message inputMessage: MessageDraft,
        summaryInfo: JSONObject,
        isSMS: Bool
    ) -> MessageDraft {
        var message = inputMessage
        guard let parts = reactionParts(assocMsgType) else {
            return message
        }
        guard parts.actionType == "reacted" || parts.actionType == "unreacted" else {
            return message
        }
        message.isAction = !isSMS
        let action = PlatformSDK.PartialMessageReactionAction(
            messageID: message.linkedMessageID,
            reactionKey: parts.actionKey == "emoji" ? msgRow.associatedMessageEmoji : parts.actionKey,
            imgURL: assocMsgType == "reacted_sticker" ? reactionStickerAssetURL(rowID: msgRow.rowID) : nil,
            participantID: message.senderID
        )
        message.action = parts.actionType == "reacted"
            ? .messageReactionCreated(action)
            : .messageReactionDeleted(action)
        if parts.actionKey == "emoji" || parts.actionKey == "sticker" || supportedReactionKeys.contains(parts.actionKey) {
            message.parseTemplate = true
            let actor = msgRow.isFromMe == 1 ? "You" : "{{sender}}"
            let target = summaryInfo.string("ams").map { "\"\($0)\"" } ?? "a message"
            message.text = "\(actor) \(reactionVerbMap[assocMsgType] ?? "") \(target)"
            message.isHidden = true
        }
        return message
    }

    private func reactionParts(_ assocMsgType: String) -> (actionType: String, actionKey: String)? {
        let pieces = assocMsgType.components(separatedBy: "_")
        guard pieces.count == 2 else {
            return nil
        }
        return (pieces[0], pieces[1])
    }

    private func senderID(for row: MappedMessageRow) -> String {
        if row.isFromMe == 1 || ((row.participantID ?? "").isEmpty && row.handleID == 0) {
            return currentUserID
        }
        return row.participantID ?? ""
    }

    private func senderID(for row: MappedReactionMessageRow) -> String {
        if row.isFromMe == 1 || ((row.participantID ?? "").isEmpty && row.handleID == 0) {
            return currentUserID
        }
        return row.participantID ?? ""
    }
}
