import Foundation
import SwiftServerFoundation

struct Mapper {
    let msgRow: JSONObject
    let attachmentRows: [JSONObject]
    let reactionRows: [JSONObject]
    let currentUserID: String
    let accountID: String

    func mapMessage() throws -> [JSONObject] {
        guard (msgRow.int("schedule_type") ?? 0) == 0 else {
            return []
        }

        let attachments = attachmentRows.compactMap { attachment(from: $0) }
        let service = msgRow.string("service")
        let isSMS = service == "SMS" || service == "RCS"
        let isGroup = !(msgRow.string("room_name") ?? "").isEmpty
        let dates = MessageDates(row: msgRow)
        let summaryInfo = parseSummaryInfo()

        var partialMessage = baseMessage(dates: dates, isSMS: isSMS, isGroup: isGroup)
        applyStatusFields(to: &partialMessage, dates: dates)
        applyEditedTimestamp(to: &partialMessage, dates: dates, summaryInfo: summaryInfo)

        if let itemType = msgRow.int("item_type"), itemType != 0 {
            if let actionMessage = mapItemTypeMessage(partialMessage: partialMessage) {
                return [actionMessage]
            }
        } else {
            partialMessage.mutateDictionary("extra") { $0["shouldNotify"] = true }
        }

        var partialHeader: JSONObject = [:]
        var partialFooter = footer()

        if let payloadData = payloadData() {
            partialMessage.merge(payloadProps(from: payloadData, messageAttachments: attachments)) { _, new in new }
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
                attributes: ["entities": [[
                    "from": 0,
                    "to": subject.unicodeScalars.count,
                    "bold": true,
                ]]]
            ), at: 0)
        }

        let attachmentsByID = Dictionary(attachments.compactMap { attachment -> (String, JSONObject)? in
            guard let id = attachment.string("id") else { return nil }
            return (id, attachment)
        }, uniquingKeysWith: { first, _ in first })
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

        if let associatedGUID = msgRow.string("associated_message_guid"),
           !associatedGUID.isEmpty,
           let associatedMessage = associatedMessage(
            messages: messages,
            partialMessage: partialMessage,
            summaryInfo: summaryInfo,
            isSMS: isSMS,
            associatedGUID: associatedGUID
           ) {
            return [associatedMessage]
        }

        return messages.map { message in
            var message = message
            assignReactions(to: &message, filterIndex: messages.count == 1 ? nil : message.dictionary("extra")?.int("part"))
            return message
        }
    }

    private func baseMessage(dates: MessageDates, isSMS: Bool, isGroup: Bool) -> JSONObject {
        let sent = appleDateMilliseconds(dates.sent) ?? 0
        var message = compactDictionary([
            "id": msgRow.string("guid") ?? "",
            "cursor": dates.sent,
            "timestamp": sent,
            "sortKey": sent,
            "senderID": senderID(),
            "isSender": msgRow.int("is_from_me") == 1,
            "isErrored": msgRow.int("error") != 0,
            "isDelivered": msgRow.int("is_delivered") == 1,
            "threadID": msgRow.string("threadID"),
            "extra": compactDictionary([
                "countsAsUnread": true,
                "isSMS": isSMS ? true : nil,
            ]),
        ])
        if !isGroup, let seen = appleDateMilliseconds(dates.read) {
            message["seen"] = seen
        }
        return message
    }

    private func applyStatusFields(to message: inout JSONObject, dates: MessageDates) {
        if dateStringIsTruthy(dates.retracted) || msgRow.int("was_detonated") == 1 {
            message["isDeleted"] = true
        }
        if msgRow.int("is_read") == 1 {
            message["behavior"] = "keep_read"
        }
    }

    private func applyEditedTimestamp(to message: inout JSONObject, dates: MessageDates, summaryInfo: JSONObject) {
        let hasUnsendData = summaryInfo.dictionary("otr") != nil && summaryInfo.hasValue("rp")
        // Partial unsends update `date_edited`; don't expose that as a user-facing edit timestamp.
        guard !hasUnsendData,
              dateStringIsTruthy(dates.edited),
              let edited = appleDateMilliseconds(dates.edited) else {
            return
        }
        message["editedTimestamp"] = edited
    }

    private func applyBalloonProps(to message: inout JSONObject, header: inout JSONObject) {
        func setHeading(_ heading: String, attachment: JSONObject?) {
            header["textHeading"] = heading
            if let attachment {
                message["attachments"] = [attachment]
            }
        }

        switch msgRow.string("balloon_bundle_id") {
        case BalloonBundleID.digitalTouch:
            setHeading("Digital Touch Message", attachment: digitalTouchAttachment())
        case BalloonBundleID.handwriting:
            setHeading("Handwritten Message", attachment: handwritingAttachment())
        case BalloonBundleID.businessExtension:
            header["textHeading"] = "Business Chat Extension"
        default:
            break
        }
    }

    private func digitalTouchAttachment() -> JSONObject? {
        guard let data = msgRow.dataURI("payload_data"),
              let uuid = stringFromDataSlice(data, start: data.count - uuidStart - uuidLength, length: uuidLength),
              isUUID(uuid) else {
            return nil
        }
        return [
            "id": uuid,
            "type": "video",
            "isGif": true,
            // Prefer asset:// because Messages.app can take a few seconds to write this file to disk.
            "srcURL": digitalTouchAssetURL(uuid: uuid),
            "size": ["width": 144, "height": 180],
        ]
    }

    private func handwritingAttachment() -> JSONObject? {
        guard let data = msgRow.dataURI("payload_data"),
              let uuid = stringFromDataSlice(data, start: uuidStart, length: uuidLength),
              isUUID(uuid) else {
            return nil
        }
        return [
            "id": uuid,
            "type": "img",
            "isGif": true,
            "srcURL": handwritingAssetURL(uuid: uuid),
        ]
    }

    private func applySiriFooter(summaryInfo: JSONObject, footer: inout JSONObject) {
        guard !summaryInfo.isEmpty, summaryInfo.string("amsa") == "com.apple.siri" else {
            return
        }
        footer["textFooter"] = "Sent with Siri"
    }

    private func applyThreadOriginator(to header: inout JSONObject) {
        guard let originatorGUID = msgRow.string("thread_originator_guid"), !originatorGUID.isEmpty else {
            return
        }
        let rawPartIndex = msgRow.string("thread_originator_part")?
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
        header["linkedMessageID"] = originatorGUID + (partIndex.isEmpty ? "" : "_\(partIndex)")
    }

    private func fallbackMessageParts(summaryInfo: JSONObject, attachments: [JSONObject]) -> [MessagePart] {
        if msgRow.dataURI("attributedBody") == nil, summaryInfo.hasValue("rp"), summaryInfo.dictionary("otr") != nil {
            return [.unsent(index: 0, end: 0)]
        }
        let text = removeObjectReplacementCharacter(msgRow.string("text") ?? "")
            .replacingOccurrences(of: imessageExtensionCharacter, with: "")
        return [.text(index: 0, end: 0, text: text, attributes: nil)]
            + attachments.enumerated().map { offset, attachment in
                .attachment(index: offset + 1, end: 0, attachmentID: attachment.string("id") ?? "")
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
        partialMessage: JSONObject,
        partialHeader: JSONObject,
        partialFooter: JSONObject,
        attachmentsByID: [String: JSONObject]
    ) -> [JSONObject] {
        parts.enumerated().map { partIndex, part in
            var message = partialMessage
            if parts.count > 1 {
                message.mutateDictionary("extra") { $0["part"] = part.index }
            }
            if partIndex == 0 {
                message.merge(partialHeader) { _, new in new }
            }
            if partIndex == parts.count - 1 {
                message.merge(partialFooter) { _, new in new }
            }
            if part.index != 0 {
                message["id"] = "\(message.string("id") ?? "")_\(part.index)"
            }
            apply(part, to: &message, attachmentsByID: attachmentsByID)
            return message
        }
    }

    private func apply(_ part: MessagePart, to message: inout JSONObject, attachmentsByID: [String: JSONObject]) {
        switch part {
        case let .text(_, _, text, attributes):
            message["text"] = text
            if let attributes {
                message["textAttributes"] = attributes
            }
        case let .attachment(_, _, attachmentID):
            if let attachment = attachmentsByID[attachmentID] {
                message["attachments"] = [attachment]
            }
        case .unsent:
            message["isAction"] = true
            message["parseTemplate"] = true
            message.removeValue(forKey: "editedTimestamp")
            message["text"] = "{{sender}} unsent a message"
        }
    }

    private func shouldKeepMessage(_ message: JSONObject) -> Bool {
        if let attachments = message["attachments"] as? [JSONObject], !attachments.isEmpty {
            return true
        }
        if let text = message.string("text"), !text.isEmpty {
            return true
        }
        return !(message.string("textHeading") ?? "").isEmpty
    }

    private func addingInlineSubject(_ subject: String, to message: JSONObject) -> JSONObject {
        var message = message
        let currentText = message.string("text") ?? ""
        message["text"] = "\(subject)\n\(currentText)"
        let subjectLength = subject.unicodeScalars.count
        let existing = ((message.dictionary("textAttributes")?["entities"] as? [JSONObject]) ?? []).map { entity in
            var shifted = entity
            shifted["from"] = subjectLength + 1 + (entity.int("from") ?? 0)
            shifted["to"] = subjectLength + 1 + (entity.int("to") ?? 0)
            return shifted
        }
        message["textAttributes"] = [
            "entities": [[
                "from": 0,
                "to": subjectLength,
                "bold": true,
            ]] + existing,
        ]
        return message
    }
}

private struct MessageDates {
    let sent: String?
    let read: String?
    let edited: String?
    let retracted: String?

    init(row: JSONObject) {
        sent = row.string("dateString") ?? row.string("date")
        read = row.string("dateReadString") ?? row.string("date_read")
        edited = row.string("dateEditedString") ?? row.string("date_edited")
        retracted = row.string("dateRetractedString") ?? row.string("date_retracted")
    }
}
