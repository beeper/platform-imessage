import Foundation

extension Mapper {
    func attachment(from attachmentRow: JSONObject) -> JSONObject? {
        guard attachmentRow["transfer_state"] != nil else {
            return nil
        }
        let ext = attachmentRow.string("ext") ?? ""
        let fileName = attachmentRow.string("fileName")
        let filePath = attachmentRow.string("filePath")
        var common = compactDictionary([
            "id": attachmentRow.string("attachmentID"),
            "fileName": fileName,
            "fileSize": attachmentRow.int("total_bytes"),
            "loading": attachmentRow.int("transfer_state") != IMFileTransferState.finished,
        ])
        common["srcURL"] = attachmentRow["filePath"] ?? NSNull()
        if let filePath, !filePath.isEmpty {
            common["srcURL"] = URL(fileURLWithPath: filePath).absoluteString
        }
        if imageExtensions.contains(ext) || ext == "pluginpayloadattachment" {
            if ext == "png" {
                common["srcURL"] = "asset://$accountID/\((filePath ?? "").utf8.map { String(format: "%02x", $0) }.joined())"
            }
            common["type"] = "img"
            common["size"] = attachmentRow["size"]
            common["isSticker"] = attachmentRow.int("is_sticker") == 1
            return common
        }
        if videoExtensions.contains(ext) {
            common["type"] = "video"
            return common
        }
        if audioExtensions.contains(ext) {
            common["isVoiceNote"] = msgRow.int("is_audio_message") == 1
            common["type"] = "audio"
            return common
        }
        common["type"] = "unknown"
        return common
    }

    func mapItemTypeMessage(partialMessage: JSONObject) -> JSONObject? {
        var message = partialMessage
        message["isAction"] = true
        message["parseTemplate"] = true
        switch msgRow.int("item_type") ?? 0 {
        case 1:
            message["behavior"] = "silent"
            let removed = msgRow.int("group_action_type") == 1
            let otherID = msgRow.string("otherID") ?? ""
            message["text"] = removed
                ? "{{sender}} removed {{\(otherID)}} from the conversation"
                : "{{sender}} added {{\(otherID)}} to the conversation"
            message["action"] = [
                "type": removed ? "thread_participants_removed" : "thread_participants_added",
                "participantIDs": [otherID],
                "actorParticipantID": message.string("senderID") ?? "",
            ]
        case 2:
            message["behavior"] = "silent"
            if let title = msgRow.string("group_title") {
                message["text"] = "{{sender}} named the conversation \"\(title)\""
            } else {
                message["text"] = "{{sender}} removed the name from the conversation"
            }
            message["action"] = [
                "type": "thread_title_updated",
                "title": msgRow["group_title"] ?? NSNull(),
                "actorParticipantID": message.string("senderID") ?? "",
            ]
        case 3:
            message["behavior"] = "silent"
            let actionType = msgRow.int("group_action_type")
            if actionType == 1 || actionType == 2 {
                message["text"] = actionType == 1 ? "{{sender}} changed the group photo" : "{{sender}} removed the group photo"
                message["attachments"] = [JSONObject]()
                message["action"] = [
                    "type": "thread_img_changed",
                    "actorParticipantID": message.string("senderID") ?? "",
                ]
            } else if actionType == 3 || actionType == 4 || actionType == 6 {
                message["text"] = actionType == 6 ? "{{sender}} removed the background" : "{{sender}} changed the background"
            } else if actionType == 0 {
                let sender = message.string("senderID") ?? ""
                message["text"] = "{{sender}} left the conversation"
                message["action"] = [
                    "type": "thread_participants_removed",
                    "actorParticipantID": sender,
                    "participantIDs": [sender],
                ]
            }
        case 4:
            message["behavior"] = "silent"
            message["text"] = msgRow.int("share_status") == 1
                ? "{{sender}} stopped sharing location"
                : "{{sender}} started sharing location"
        case 5:
            message["behavior"] = "silent"
            message["text"] = msgRow.string("balloon_bundle_id") == BalloonBundleID.digitalTouch
                ? "{{sender}} kept Digital Touch Message from you."
                : "{{sender}} kept an audio message from you."
        case 6:
            message["text"] = "FaceTime Call"
        default:
            return nil
        }
        return message
    }
}
