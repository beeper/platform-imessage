import Foundation
import IMDatabase

extension Mapper {
    func attachment(from attachmentRow: MappedAttachmentRow) -> JSONObject? {
        guard let transferState = attachmentRow.transferState else {
            return nil
        }
        let ext = attachmentRow.ext ?? ""
        let fileName = attachmentRow.fileName
        let filePath = attachmentRow.filePath
        var common = compactDictionary([
            "id": attachmentRow.attachmentID,
            "fileName": fileName,
            "fileSize": attachmentRow.totalBytes,
            "loading": transferState != IMFileTransferState.finished,
        ])
        if let filePath, !filePath.isEmpty {
            common["srcURL"] = fileURLString(filePath)
        } else {
            common["srcURL"] = attachmentRow.filePath ?? NSNull()
        }
        if imageExtensions.contains(ext) || ext == "pluginpayloadattachment" {
            if ext == "png" {
                common["srcURL"] = fileAttachmentAssetURL(filePath: filePath ?? "")
            }
            common["type"] = "img"
            common["size"] = attachmentRow.size
            common["isSticker"] = attachmentRow.isSticker == 1
            return common
        }
        if videoExtensions.contains(ext) {
            common["type"] = "video"
            return common
        }
        if audioExtensions.contains(ext) {
            common["isVoiceNote"] = msgRow.isAudioMessage == 1
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
        switch msgRow.itemType {
        case 1:
            message["behavior"] = "silent"
            let removed = msgRow.groupActionType == 1
            let otherID = msgRow.otherID ?? ""
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
            if let title = msgRow.groupTitle {
                message["text"] = "{{sender}} named the conversation \"\(title)\""
            } else {
                message["text"] = "{{sender}} removed the name from the conversation"
            }
            message["action"] = [
                "type": "thread_title_updated",
                "title": msgRow.groupTitle as Any? ?? NSNull(),
                "actorParticipantID": message.string("senderID") ?? "",
            ]
        case 3:
            message["behavior"] = "silent"
            let actionType = msgRow.groupActionType
            switch actionType {
            case 1, 2:
                message["text"] = actionType == 1 ? "{{sender}} changed the group photo" : "{{sender}} removed the group photo"
                message["attachments"] = [JSONObject]()
                message["action"] = [
                    "type": "thread_img_changed",
                    "actorParticipantID": message.string("senderID") ?? "",
                ]
            case 3, 4, 6:
                message["text"] = actionType == 6 ? "{{sender}} removed the background" : "{{sender}} changed the background"
            case 0:
                let sender = message.string("senderID") ?? ""
                message["text"] = "{{sender}} left the conversation"
                message["action"] = [
                    "type": "thread_participants_removed",
                    "actorParticipantID": sender,
                    "participantIDs": [sender],
                ]
            default:
                break
            }
        case 4:
            message["behavior"] = "silent"
            message["text"] = msgRow.shareStatus == 1
                ? "{{sender}} stopped sharing location"
                : "{{sender}} started sharing location"
        case 5:
            message["behavior"] = "silent"
            message["text"] = msgRow.balloonBundleID == BalloonBundleID.digitalTouch
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
