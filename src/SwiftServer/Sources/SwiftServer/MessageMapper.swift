import Foundation
import SwiftServerFoundation

enum MessageMapper {
    static func mapMessageJSON(_ inputJSON: String) throws -> String {
        let inputData = try inputJSON.data(using: .utf8).orThrow(ErrorMessage("mapper input wasn't utf8"))
        let decoded = try JSONSerialization.jsonObject(with: inputData)
        let input = try (decoded as? [String: Any]).orThrow(ErrorMessage("mapper input wasn't an object"))
        let mapper = try Mapper(input: input)
        let messages = try mapper.mapMessage()
        let outputData = try JSONSerialization.data(withJSONObject: messages)
        return try String(data: outputData, encoding: .utf8).orThrow(ErrorMessage("mapper output wasn't utf8"))
    }
}

struct Mapper {
    let msgRow: [String: Any]
    let attachmentRows: [[String: Any]]
    let reactionRows: [[String: Any]]
    let currentUserID: String
    let accountID: String

    init(input: [String: Any]) throws {
        msgRow = try input.dictionary("msgRow").orThrow(ErrorMessage("mapper input missing msgRow"))
        attachmentRows = input.array("attachmentRows").compactMap { $0 as? [String: Any] }
        reactionRows = input.array("reactionRows").compactMap { $0 as? [String: Any] }
        currentUserID = try input.string("currentUserID").orThrow(ErrorMessage("mapper input missing currentUserID"))
        accountID = try input.string("accountID").orThrow(ErrorMessage("mapper input missing accountID"))
    }

    func mapMessage() throws -> [[String: Any]] {
        let attachments = attachmentRows.compactMap { mapAttachment($0) }
        let isSMS = msgRow.string("service") == "SMS" || msgRow.string("service") == "RCS"
        let isGroup = !(msgRow.string("room_name") ?? "").isEmpty

        if (msgRow.int("schedule_type") ?? 0) != 0 {
            return []
        }

        let dateString = msgRow.string("dateString") ?? msgRow.string("date")
        let dateReadString = msgRow.string("dateReadString") ?? msgRow.string("date_read")
        let dateEditedString = msgRow.string("dateEditedString") ?? msgRow.string("date_edited")
        let dateRetractedString = msgRow.string("dateRetractedString") ?? msgRow.string("date_retracted")

        var partialMessage: [String: Any] = compactDictionary([
            "id": msgRow.string("guid") ?? "",
            "cursor": dateString,
            "timestamp": appleDateMilliseconds(dateString) ?? 0,
            "sortKey": appleDateMilliseconds(dateString) ?? 0,
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
        if !isGroup, let seen = appleDateMilliseconds(dateReadString) {
            partialMessage["seen"] = seen
        }
        if dateStringIsTruthy(dateRetractedString) || msgRow.int("was_detonated") == 1 {
            partialMessage["isDeleted"] = true
        }
        if msgRow.int("is_read") == 1 {
            partialMessage["behavior"] = "keep_read"
        }

        let summaryInfo = parseSummaryInfo()
        let unsendDataPresent = summaryInfo.dictionary("otr") != nil && summaryInfo.hasValue("rp")
        if !unsendDataPresent,
           dateStringIsTruthy(dateEditedString),
           let edited = appleDateMilliseconds(dateEditedString) {
            partialMessage["editedTimestamp"] = edited
        }

        if (msgRow.int("item_type") ?? 0) != 0 {
            if let actionMessage = mapItemTypeMessage(partialMessage: partialMessage) {
                return [actionMessage]
            }
        } else {
            var extra = partialMessage.dictionary("extra") ?? [:]
            extra["shouldNotify"] = true
            partialMessage["extra"] = extra
        }

        var partialHeader: [String: Any] = [:]
        var partialFooter = footer()

        if let payloadData = getPayloadData() {
            partialMessage.merge(getPayloadProps(payloadData: payloadData, msgAttachments: attachments)) { _, new in new }
        }

        switch msgRow.string("balloon_bundle_id") {
        case BalloonBundleID.digitalTouch:
            partialHeader["textHeading"] = "Digital Touch Message"
            if let data = msgRow.dataURI("payload_data"),
               let uuid = stringFromDataSlice(data, start: data.count - uuidStart - uuidLength, length: uuidLength),
               isUUID(uuid) {
                partialMessage["attachments"] = [[
                    "id": uuid,
                    "type": "video",
                    "isGif": true,
                    "srcURL": "asset://$accountID/dt/\(uuid).mov",
                    "size": ["width": 144, "height": 180],
                ]]
            }
        case BalloonBundleID.handwriting:
            partialHeader["textHeading"] = "Handwritten Message"
            if let data = msgRow.dataURI("payload_data"),
               let uuid = stringFromDataSlice(data, start: uuidStart, length: uuidLength),
               isUUID(uuid) {
                partialMessage["attachments"] = [[
                    "id": uuid,
                    "type": "img",
                    "isGif": true,
                    "srcURL": "asset://$accountID/hw/\(uuid).png",
                ]]
            }
        case BalloonBundleID.businessExtension:
            partialHeader["textHeading"] = "Business Chat Extension"
        default:
            break
        }

        if !summaryInfo.isEmpty, summaryInfo.string("amsa") == "com.apple.siri" {
            partialFooter["textFooter"] = "Sent with Siri"
        }

        if let originatorGUID = msgRow.string("thread_originator_guid"), !originatorGUID.isEmpty {
            var partIndex = msgRow.string("thread_originator_part")?.components(separatedBy: ":").first ?? ""
            if partIndex == "0" {
                partIndex = ""
            }
            if partIndex == "18446744073709551615" {
                partIndex = "-1"
            }
            partialHeader["linkedMessageID"] = originatorGUID + (partIndex.isEmpty ? "" : "_\(partIndex)")
        }

        var messageParts = decodeAttributedMessageParts(summaryInfo: summaryInfo)
        if messageParts.isEmpty {
            if msgRow.dataURI("attributedBody") == nil, summaryInfo.hasValue("rp"), summaryInfo.dictionary("otr") != nil {
                messageParts = [.unsent(index: 0, end: 0)]
            } else {
                let text = removeObjectReplacementCharacter(msgRow.string("text") ?? "")
                    .replacingOccurrences(of: imessageExtensionCharacter, with: "")
                messageParts = [.text(index: 0, end: 0, text: text, attributes: nil)]
                messageParts.append(contentsOf: attachments.enumerated().map { offset, attachment in
                    .attachment(index: offset + 1, end: 0, attachmentID: attachment.string("id") ?? "")
                })
            }
        }

        let addSubjectInline = subject().map { subject in
            if case let .text(_, _, text, _) = messageParts[0] {
                return !subject.isEmpty && !text.isEmpty
            }
            return false
        } ?? false
        if let subject = subject(), !subject.isEmpty, !addSubjectInline {
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

        var messages = messageParts.enumerated().map { partIndex, part -> [String: Any] in
            var message = partialMessage
            if messageParts.count > 1 {
                var extra = (message["extra"] as? [String: Any]) ?? [:]
                extra["part"] = part.index
                message["extra"] = extra
            }
            if partIndex == 0 {
                message.merge(partialHeader) { _, new in new }
            }
            if partIndex == messageParts.count - 1 {
                message.merge(partialFooter) { _, new in new }
            }
            if part.index != 0 {
                message["id"] = "\(message.string("id") ?? "")_\(part.index)"
            }

            switch part {
            case let .text(_, _, text, attributes):
                message["text"] = text
                if let attributes {
                    message["textAttributes"] = attributes
                }
            case let .attachment(_, _, attachmentID):
                if let attachment = attachments.first(where: { $0.string("id") == attachmentID }) {
                    message["attachments"] = [attachment]
                }
            case .unsent:
                message["isAction"] = true
                message["parseTemplate"] = true
                message.removeValue(forKey: "editedTimestamp")
                message["text"] = "{{sender}} unsent a message"
            }
            return message
        }.filter { message in
            if let attachments = message["attachments"] as? [[String: Any]], !attachments.isEmpty {
                return true
            }
            if let text = message.string("text"), !text.isEmpty {
                return true
            }
            if let textHeading = message.string("textHeading"), !textHeading.isEmpty {
                return true
            }
            return false
        }

        if addSubjectInline, let subject = subject(), !messages.isEmpty {
            var firstTextPart = messages[0]
            let currentText = firstTextPart.string("text") ?? ""
            firstTextPart["text"] = "\(subject)\n\(currentText)"
            let subjectLength = subject.unicodeScalars.count
            let existing = ((firstTextPart.dictionary("textAttributes")?["entities"] as? [[String: Any]]) ?? []).map { entity in
                var shifted = entity
                shifted["from"] = subjectLength + 1 + (entity.int("from") ?? 0)
                shifted["to"] = subjectLength + 1 + (entity.int("to") ?? 0)
                return shifted
            }
            firstTextPart["textAttributes"] = [
                "entities": [[
                    "from": 0,
                    "to": subjectLength,
                    "bold": true,
                ]] + existing,
            ]
            messages[0] = firstTextPart
        }

        if let associatedGUID = msgRow.string("associated_message_guid"), !associatedGUID.isEmpty {
            if let associatedMessage = associatedMessage(
                messages: messages,
                partialMessage: partialMessage,
                summaryInfo: summaryInfo,
                isSMS: isSMS,
                associatedGUID: associatedGUID
            ) {
                return [associatedMessage]
            }
        }

        return messages.map { message in
            var message = message
            assignReactions(to: &message, filterIndex: messages.count == 1 ? nil : message.dictionary("extra")?.int("part"))
            return message
        }
    }

}
