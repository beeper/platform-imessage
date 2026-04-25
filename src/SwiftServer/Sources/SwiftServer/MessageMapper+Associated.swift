import Foundation

extension Mapper {
    func footer() -> JSONObject {
        let expressiveSendStyleID = msgRow.string("expressive_send_style_id") ?? ""
        if let effect = expressiveMessages[expressiveSendStyleID] {
            return ["textFooter": "(Sent with \(effect) effect)"]
        }
        if let service = msgRow.string("service"), let footer = serviceFooters[service] {
            return ["textFooter": footer]
        }
        return [:]
    }

    func associatedMessage(
        messages: [JSONObject],
        partialMessage: JSONObject,
        summaryInfo: JSONObject,
        isSMS: Bool,
        associatedGUID: String
    ) -> JSONObject? {
        let firstTextPart = messages.first { $0["text"] is String }
        var message = firstTextPart ?? partialMessage
        let guidRange = NSRange(associatedGUID.startIndex ..< associatedGUID.endIndex, in: associatedGUID)
        message["linkedMessageID"] = assocMsgGUIDPrefixRegex.stringByReplacingMatches(
            in: associatedGUID,
            range: guidRange,
            withTemplate: ""
        )
        guard let associatedMessageType = msgRow.int("associated_message_type"),
              let assocMsgType = associatedMessageTypes[associatedMessageType] else {
            return nil
        }

        switch assocMsgType {
        case "sticker":
            return nil
        case "heading":
            if var text = message.string("text") {
                let other = msgRow.string("participantID") ?? ""
                let isSender = message.bool("isSender") == true
                let senderName = isSender ? currentUserID : other
                let receiverName = isSender ? other : currentUserID
                text = text
                    .replacingOccurrences(of: receiverNamePlaceholder, with: "{{\(receiverName)}}")
                    .replacingOccurrences(of: senderNamePlaceholder, with: "{{\(senderName)}}")
                message["text"] = text
            }
            message["parseTemplate"] = true
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

    func assignReactions(to message: inout JSONObject, filterIndex: Int?) {
        var reactions = [JSONObject]()
        let filteredRows = reactionRows.filter { reaction in
            guard let filterIndex else {
                return true
            }
            return (reaction.string("associated_message_guid") ?? "").hasPrefix("p:\(filterIndex)/")
        }
        for reaction in filteredRows {
            guard let associatedMessageType = reaction.int("associated_message_type"),
                  let assocMsgType = associatedMessageTypes[associatedMessageType],
                  let parts = reactionParts(assocMsgType),
                  assocMsgType != "sticker" else {
                continue
            }
            let participantID = senderID(for: reaction)
            if parts.actionType == "reacted" {
                reactions.append(compactDictionary([
                    "id": participantID,
                    "reactionKey": parts.actionKey == "emoji" ? reaction.string("associated_message_emoji") : parts.actionKey,
                    "participantID": participantID,
                    "imgURL": parts.actionKey == "sticker" ? reactionStickerAssetURL(rowID: reaction.int("ROWID") ?? 0) : nil,
                ]))
            } else if parts.actionType == "unreacted", let index = reactions.firstIndex(where: { $0.string("id") == participantID }) {
                reactions.remove(at: index)
            }
        }
        if !reactions.isEmpty {
            message["reactions"] = reactions
        }
    }

    func subject() -> String? {
        guard let subject = msgRow.string("subject"), !subject.isEmpty else {
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
        message inputMessage: JSONObject,
        summaryInfo: JSONObject,
        isSMS: Bool
    ) -> JSONObject {
        var message = inputMessage
        guard let parts = reactionParts(assocMsgType) else {
            return message
        }
        guard let reactionType = [
            "reacted": "message_reaction_created",
            "unreacted": "message_reaction_deleted",
        ][parts.actionType] else {
            return message
        }
        message["isAction"] = !isSMS
        message["action"] = compactDictionary([
            "type": reactionType,
            "messageID": message.string("linkedMessageID"),
            "participantID": message.string("senderID"),
            "imgURL": assocMsgType == "reacted_sticker" ? reactionStickerAssetURL(rowID: msgRow.int("ROWID") ?? 0) : nil,
            "reactionKey": parts.actionKey == "emoji" ? msgRow.string("associated_message_emoji") : parts.actionKey,
        ])
        if parts.actionKey == "emoji" || parts.actionKey == "sticker" || supportedReactionKeys.contains(parts.actionKey) {
            message["parseTemplate"] = true
            let actor = msgRow.int("is_from_me") == 1 ? "You" : "{{sender}}"
            let target = summaryInfo.string("ams").map { "\"\($0)\"" } ?? "a message"
            message["text"] = "\(actor) \(reactionVerbMap[assocMsgType] ?? "") \(target)"
            message["isHidden"] = true
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

    private func senderID(for row: JSONObject) -> String {
        if row.int("is_from_me") == 1 || ((row.string("participantID") ?? "").isEmpty && row.int("handle_id") == 0) {
            return currentUserID
        }
        return row.string("participantID") ?? ""
    }
}
