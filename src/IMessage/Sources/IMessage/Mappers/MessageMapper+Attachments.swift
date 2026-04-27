import Foundation
import IMDatabase
import PlatformSDK

extension Mapper {
    func attachment(from attachmentRow: MappedAttachmentRow) -> PlatformSDK.Attachment? {
        guard let transferState = attachmentRow.transferState else {
            return nil
        }
        let ext = attachmentRow.ext ?? ""
        let fileName = attachmentRow.fileName
        let filePath = attachmentRow.filePath
        let id = attachmentRow.attachmentID ?? ""
        var srcURL: String?
        if let filePath, !filePath.isEmpty {
            srcURL = fileURLString(filePath)
        } else {
            srcURL = attachmentRow.filePath
        }
        let size = attachmentRow.size.flatMap(PlatformSDK.Size.init(size:))

        if imageExtensions.contains(ext) || ext == "pluginpayloadattachment" {
            var imageSrcURL = srcURL
            if ext == "png" {
                imageSrcURL = fileAttachmentAssetURL(filePath: filePath ?? "")
            }
            return PlatformSDK.Attachment(
                id: id,
                type: .img,
                size: size,
                fileName: fileName,
                fileSize: attachmentRow.totalBytes.map(Int64.init),
                loading: transferState != IMFileTransferState.finished,
                isSticker: attachmentRow.isSticker == 1,
                srcURL: imageSrcURL
            )
        }
        if videoExtensions.contains(ext) {
            return PlatformSDK.Attachment(
                id: id,
                type: .video,
                fileName: fileName,
                fileSize: attachmentRow.totalBytes.map(Int64.init),
                loading: transferState != IMFileTransferState.finished,
                srcURL: srcURL
            )
        }
        if audioExtensions.contains(ext) {
            return PlatformSDK.Attachment(
                id: id,
                type: .audio,
                fileName: fileName,
                fileSize: attachmentRow.totalBytes.map(Int64.init),
                loading: transferState != IMFileTransferState.finished,
                isVoiceNote: msgRow.isAudioMessage == 1,
                srcURL: srcURL
            )
        }
        return PlatformSDK.Attachment(
            id: id,
            type: .unknown,
            fileName: fileName,
            fileSize: attachmentRow.totalBytes.map(Int64.init),
            loading: transferState != IMFileTransferState.finished,
            srcURL: srcURL
        )
    }

    func mapItemTypeMessage(partialMessage: MessageDraft) -> MessageDraft? {
        var message = partialMessage
        message.isAction = true
        message.parseTemplate = true
        switch msgRow.itemType {
        case 1:
            message.behavior = .silent
            let removed = msgRow.groupActionType == 1
            let otherID = msgRow.otherID ?? ""
            message.text = removed
                ? "{{sender}} removed {{\(otherID)}} from the conversation"
                : "{{sender}} added {{\(otherID)}} to the conversation"
            message.action = removed
                ? .threadParticipantsRemoved(participantIDs: [otherID], actorParticipantID: message.senderID, participants: nil)
                : .threadParticipantsAdded(participantIDs: [otherID], actorParticipantID: message.senderID, participants: nil)
        case 2:
            message.behavior = .silent
            if let title = msgRow.groupTitle {
                message.text = "{{sender}} named the conversation \"\(title)\""
            } else {
                message.text = "{{sender}} removed the name from the conversation"
            }
            message.action = .threadTitleUpdated(title: msgRow.groupTitle, actorParticipantID: message.senderID)
        case 3:
            message.behavior = .silent
            let actionType = msgRow.groupActionType
            switch actionType {
            case 1, 2:
                message.text = actionType == 1 ? "{{sender}} changed the group photo" : "{{sender}} removed the group photo"
                message.attachments = []
                message.action = .threadImgChanged(actorParticipantID: message.senderID)
            case 3, 4, 6:
                message.text = actionType == 6 ? "{{sender}} removed the background" : "{{sender}} changed the background"
            case 0:
                let sender = message.senderID
                message.text = "{{sender}} left the conversation"
                message.action = .threadParticipantsRemoved(participantIDs: [sender], actorParticipantID: sender, participants: nil)
            default:
                break
            }
        case 4:
            message.behavior = .silent
            message.text = msgRow.shareStatus == 1
                ? "{{sender}} stopped sharing location"
                : "{{sender}} started sharing location"
        case 5:
            message.behavior = .silent
            message.text = msgRow.balloonBundleID == BalloonBundleID.digitalTouch
                ? "{{sender}} kept Digital Touch Message from you."
                : "{{sender}} kept an audio message from you."
        case 6:
            message.text = "FaceTime Call"
        default:
            return nil
        }
        return message
    }
}

private extension PlatformSDK.Size {
    init?(size: [String: Int]) {
        guard let width = size["width"], let height = size["height"] else {
            return nil
        }
        self.init(width: Double(width), height: Double(height))
    }
}
