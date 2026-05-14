import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

struct Mapper {
    let msgRow: MappedMessageRow
    let attachmentRows: [MappedAttachmentRow]
    let reactionRows: [MappedReactionMessageRow]
    let currentUserID: String
    let accountID: String

    func mapMessage() throws -> [PlatformSDK.Message] {
        guard msgRow.scheduleType == 0 else {
            return []
        }

        let attachments = attachmentRows.compactMap { attachment(from: $0) }
        let service = msgRow.service
        let isSMS = service == "SMS" || service == "RCS"
        let isGroup = !(msgRow.roomName ?? "").isEmpty
        let dates = MessageDates(row: msgRow)
        let summaryInfo = parseSummaryInfo()

        var partialMessage = baseMessage(dates: dates, isSMS: isSMS, isGroup: isGroup)
        applyStatusFields(to: &partialMessage, dates: dates)
        applyEditedTimestamp(to: &partialMessage, dates: dates, summaryInfo: summaryInfo)

        if msgRow.itemType != 0 {
            if let actionMessage = mapItemTypeMessage(partialMessage: partialMessage) {
                return [actionMessage.message()]
            }
        } else {
            partialMessage.extra["shouldNotify"] = true
        }

        var partialHeader = MessagePatch()
        var partialFooter = footer()

        if let payloadData = payloadData() {
            payloadProps(from: payloadData, messageAttachments: attachments).apply(to: &partialMessage)
        }

        applyBalloonProps(to: &partialMessage, header: &partialHeader)
        applySiriFooter(summaryInfo: summaryInfo, footer: &partialFooter)
        applyThreadOriginator(to: &partialHeader)

        let decodedMessageParts = decodeAttributedMessageParts(summaryInfo: summaryInfo)
        var messageParts = decodedMessageParts.isEmpty
            ? fallbackMessageParts(summaryInfo: summaryInfo, attachments: attachments)
            : decodedMessageParts

        let subject = subject()
        let addSubjectInline = shouldAddSubjectInline(subject, to: messageParts)
        if let subject, !addSubjectInline {
            messageParts.insert(.text(
                index: -1,
                end: 0,
                text: subject,
                attributes: PlatformSDK.TextAttributes(entities: [
                    PlatformSDK.TextEntity(from: 0, to: subject.unicodeScalars.count, bold: true),
                ])
            ), at: 0)
        }

        let attachmentsByID = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var messages = makeMessages(
            from: messageParts,
            partialMessage: partialMessage,
            partialHeader: partialHeader,
            partialFooter: partialFooter,
            attachmentsByID: attachmentsByID
        ).filter(shouldKeepMessage)

        if addSubjectInline, let subject, !messages.isEmpty {
            messages[0] = addingInlineSubject(subject, to: messages[0])
        }

        if let associatedGUID = msgRow.associatedMessageGUID,
           !associatedGUID.isEmpty {
            if let associatedMessage = associatedMessage(
                messages: &messages,
                partialMessage: partialMessage,
                summaryInfo: summaryInfo,
                isSMS: isSMS,
                associatedGUID: associatedGUID
            ) {
                return [associatedMessage.message()]
            }
        }

        return messages.map { message in
            var message = message
            assignReactions(to: &message, filterIndex: messages.count == 1 ? nil : message.extra.int("part"))
            return message.message()
        }
    }

    private func baseMessage(dates: MessageDates, isSMS: Bool, isGroup: Bool) -> MessageDraft {
        let sent = appleDateMilliseconds(dates.sent) ?? 0
        var extra: JSONObject = ["countsAsUnread": true]
        if isSMS {
            extra["isSMS"] = true
        }
        var message = MessageDraft(
            id: msgRow.guid,
            timestamp: sent,
            senderID: messageSenderID(for: msgRow, currentUserID: currentUserID),
            seen: nil,
            isDelivered: msgRow.isDelivered == 1,
            isSender: msgRow.isFromMe == 1,
            isErrored: msgRow.error != 0,
            threadID: msgRow.threadID,
            sortKey: sent,
            cursor: dates.sent.map(String.init),
            extra: extra
        )
        if !isGroup, let seen = appleDateMilliseconds(dates.read) {
            message.seen = .timestamp(seen)
        }
        return message
    }

    private func applyStatusFields(to message: inout MessageDraft, dates: MessageDates) {
        if appleDateIsTruthy(dates.retracted) || msgRow.wasDetonated == 1 {
            message.isDeleted = true
        }
        if msgRow.isRead == 1 {
            message.behavior = .keepRead
        }
    }

    private func applyEditedTimestamp(to message: inout MessageDraft, dates: MessageDates, summaryInfo: JSONObject) {
        let hasUnsendData = summaryInfo.dictionary("otr") != nil && summaryInfo.hasValue("rp")
        // Partial unsends update `date_edited`; don't expose that as a user-facing edit timestamp.
        guard !hasUnsendData,
              appleDateIsTruthy(dates.edited),
              let edited = appleDateMilliseconds(dates.edited) else {
            return
        }
        message.editedTimestamp = edited
    }

    private func applyBalloonProps(to message: inout MessageDraft, header: inout MessagePatch) {
        func setHeading(_ heading: String, attachment: PlatformSDK.Attachment?) {
            header.textHeading = heading
            if let attachment {
                message.attachments = [attachment]
            }
        }

        switch msgRow.balloonBundleID {
        case BalloonBundleID.digitalTouch:
            setHeading("Digital Touch Message", attachment: digitalTouchAttachment())
        case BalloonBundleID.handwriting:
            setHeading("Handwritten Message", attachment: handwritingAttachment())
        case BalloonBundleID.businessExtension:
            header.textHeading = "Business Chat Extension"
        default:
            break
        }
    }

    private func digitalTouchAttachment() -> PlatformSDK.Attachment? {
        guard let data = msgRow.payloadData,
              let uuid = stringFromDataSlice(data, start: data.count - uuidStart - uuidLength, length: uuidLength),
              isUUID(uuid) else {
            return nil
        }
        return PlatformSDK.Attachment(
            id: uuid,
            type: .video,
            size: PlatformSDK.Size(width: 144, height: 180),
            isGif: true,
            // Prefer asset:// because Messages.app can take a few seconds to write this file to disk.
            srcURL: digitalTouchAssetURL(uuid: uuid)
        )
    }

    private func handwritingAttachment() -> PlatformSDK.Attachment? {
        guard let data = msgRow.payloadData,
              let uuid = stringFromDataSlice(data, start: uuidStart, length: uuidLength),
              isUUID(uuid) else {
            return nil
        }
        return PlatformSDK.Attachment(
            id: uuid,
            type: .img,
            isGif: true,
            srcURL: handwritingAssetURL(uuid: uuid)
        )
    }

    private func applySiriFooter(summaryInfo: JSONObject, footer: inout MessagePatch) {
        guard !summaryInfo.isEmpty, summaryInfo.string("amsa") == "com.apple.siri" else {
            return
        }
        footer.textFooter = "Sent with Siri"
    }

    private func applyThreadOriginator(to header: inout MessagePatch) {
        guard let originatorGUID = msgRow.threadOriginatorGUID, !originatorGUID.isEmpty else {
            return
        }
        let rawPartIndex = msgRow.threadOriginatorPart?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let partIndex: String
        switch rawPartIndex {
        case "0":
            partIndex = ""
        case String(UInt64.max):
            // UInt64.max stored where -1 was meant (https://stackoverflow.com/questions/40608111/why-is-18446744073709551615-1-true)
            partIndex = "-1"
        default:
            partIndex = rawPartIndex
        }
        header.linkedMessageID = originatorGUID + (partIndex.isEmpty ? "" : "_\(partIndex)")
    }

    private func fallbackMessageParts(summaryInfo: JSONObject, attachments: [PlatformSDK.Attachment]) -> [MessagePart] {
        if msgRow.attributedBody == nil, summaryInfo.hasValue("rp"), summaryInfo.dictionary("otr") != nil {
            return [.unsent(index: 0, end: 0)]
        }
        let text = removeObjectReplacementCharacter(msgRow.text ?? "")
            .replacingOccurrences(of: imessageExtensionCharacter, with: "")
        return [.text(index: 0, end: 0, text: text, attributes: nil)]
            + attachments.enumerated().map { offset, attachment in
                .attachment(index: offset + 1, end: 0, attachmentID: attachment.id)
            }
    }

    private func shouldAddSubjectInline(_ subject: String?, to parts: [MessagePart]) -> Bool {
        guard let subject,
              !subject.isEmpty,
              let firstPart = parts.first,
              case let .text(_, _, text, _) = firstPart else {
            return false
        }
        return !text.isEmpty
    }

    private func makeMessages(
        from parts: [MessagePart],
        partialMessage: MessageDraft,
        partialHeader: MessagePatch,
        partialFooter: MessagePatch,
        attachmentsByID: [String: PlatformSDK.Attachment]
    ) -> [MessageDraft] {
        parts.enumerated().map { partIndex, part in
            var message = partialMessage
            if parts.count > 1 {
                message.extra["part"] = part.index
            }
            if partIndex == 0 {
                partialHeader.apply(to: &message)
            }
            if partIndex == parts.count - 1 {
                partialFooter.apply(to: &message)
            }
            if part.index != 0 {
                message.id = "\(message.id)_\(part.index)"
            }
            apply(part, to: &message, attachmentsByID: attachmentsByID)
            return message
        }
    }

    private func apply(_ part: MessagePart, to message: inout MessageDraft, attachmentsByID: [String: PlatformSDK.Attachment]) {
        switch part {
        case let .text(_, _, text, attributes):
            message.text = text
            if let attributes {
                message.textAttributes = attributes
            }
        case let .attachment(_, _, attachmentID):
            if let attachment = attachmentsByID[attachmentID] {
                message.attachments = [attachment]
            }
        case .unsent:
            message.isAction = true
            message.parseTemplate = true
            message.editedTimestamp = nil
            message.text = "{{sender}} unsent a message"
        }
    }

    private func shouldKeepMessage(_ message: MessageDraft) -> Bool {
        if let attachments = message.attachments, !attachments.isEmpty {
            return true
        }
        if let text = message.text, !text.isEmpty {
            return true
        }
        return !(message.textHeading ?? "").isEmpty
    }

    private func addingInlineSubject(_ subject: String, to message: MessageDraft) -> MessageDraft {
        var message = message
        let currentText = message.text ?? ""
        message.text = "\(subject)\n\(currentText)"
        let subjectLength = subject.unicodeScalars.count
        let existing = (message.textAttributes?.entities ?? []).map { $0.offsetting(by: subjectLength + 1) }
        message.textAttributes = PlatformSDK.TextAttributes(entities: [
            PlatformSDK.TextEntity(from: 0, to: subjectLength, bold: true),
        ] + existing)
        return message
    }
}

extension Mapper {
    init(
        msgRow: JSONObject,
        attachmentRows: [JSONObject],
        reactionRows: [JSONObject],
        currentUserID: String,
        accountID: String
    ) throws {
        try self.init(
            msgRow: MappedMessageRow(object: msgRow),
            attachmentRows: attachmentRows.map(MappedAttachmentRow.init(object:)),
            reactionRows: reactionRows.map(MappedReactionMessageRow.init(object:)),
            currentUserID: currentUserID,
            accountID: accountID
        )
    }
}

private struct MessageDates {
    let sent: Int?
    let read: Int?
    let edited: Int?
    let retracted: Int?

    init(row: MappedMessageRow) {
        sent = row.date
        read = row.dateRead
        edited = row.dateEdited
        retracted = row.dateRetracted
    }
}
