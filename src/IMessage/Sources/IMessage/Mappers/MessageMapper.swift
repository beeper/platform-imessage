import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

struct Mapper {
    let messageRow: MappedMessageRow
    let attachmentRows: [MappedAttachmentRow]
    let reactionRows: [MappedReactionMessageRow]
    let currentUserID: String
    let accountID: String

    func mapMessage() throws -> [PlatformSDK.Message] {
        guard messageRow.scheduleType == 0 else {
            return []
        }

        let attachments = attachmentRows.compactMap { attachment(from: $0) }
        let service = messageRow.service
        let isSMS = service == "SMS" || service == "RCS"
        let isGroup = !(messageRow.roomName ?? "").isEmpty
        let dates = MessageDates(row: messageRow)
        let summaryInfo = parseSummaryInfo()

        var partialMessage = baseMessage(dates: dates, isSMS: isSMS, isGroup: isGroup)
        applyStatusFields(to: &partialMessage, dates: dates)
        applyEditedTimestamp(to: &partialMessage, dates: dates, summaryInfo: summaryInfo)
        let bundleKind = BalloonBundleKind(messageRow.balloonBundleID)

        if messageRow.itemType != 0 {
            if hasBrandLogoImageAttachment() {
                return []
            }
            if let actionMessage = mapItemTypeMessage(partialMessage: partialMessage) {
                return [actionMessage.message()]
            }
        } else {
            partialMessage.extra["shouldNotify"] = true
        }

        var partialHeader = MessagePatch()
        var partialFooter = footer()

        let payloadData = payloadData()
        if let payloadData {
            payloadProps(
                from: payloadData,
                messageAttachments: attachments,
                bundleKind: bundleKind
            ).apply(to: &partialMessage)
        }

        applyBalloonProps(to: &partialMessage, header: &partialHeader, bundleKind: bundleKind)
        applySiriFooter(summaryInfo: summaryInfo, footer: &partialFooter)
        applyThreadOriginator(to: &partialHeader)

        let decodedMessageParts = decodeAttributedMessageParts(summaryInfo: summaryInfo)
        var messageParts = decodedMessageParts.isEmpty
            ? fallbackMessageParts(summaryInfo: summaryInfo, attachments: attachments)
            : decodedMessageParts
        let editHistory = editHistoryByPart(summaryInfo: summaryInfo)

        let subject = subject()
        let addSubjectInline = shouldAddSubjectInline(subject, to: messageParts)
        if let subject, !addSubjectInline {
            messageParts.insert(.text(
                index: -1,
                originalPart: nil,
                end: 0,
                text: subject,
                attributes: PlatformSDK.TextAttributes(entities: [
                    PlatformSDK.TextEntity(from: 0, to: subject.unicodeScalars.count, bold: true),
                ])
            ), at: 0)
        }

        let attachmentsByID = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let associatedTarget = messageRow.associatedMessageGUID?.nonEmpty.map(parseAssociatedMessageTarget)
        var messages = makeMessages(
            from: messageParts,
            partialMessage: partialMessage,
            partialHeader: partialHeader,
            partialFooter: partialFooter,
            attachmentsByID: attachmentsByID,
            editHistory: editHistory
        ).filter(shouldKeepMessage)

        if messages.isEmpty,
           let placeholder = unsupportedBalloonPlaceholder(
            partialMessage: partialMessage,
            payloadData: payloadData,
            bundleKind: bundleKind,
            linkedMessageID: associatedTarget?.messageID
           ) {
            messages = [placeholder]
        }

        if addSubjectInline, let subject, !messages.isEmpty {
            messages[0] = addingInlineSubject(subject, to: messages[0])
        }

        if let associatedTarget {
            if let associatedMessage = associatedMessage(
                messages: &messages,
                partialMessage: partialMessage,
                summaryInfo: summaryInfo,
                isSMS: isSMS,
                associatedTarget: associatedTarget
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
            id: messageRow.guid,
            timestamp: sent,
            senderID: messageSenderID(for: messageRow, currentUserID: currentUserID),
            seen: nil,
            isDelivered: messageRow.isDelivered == 1,
            isSender: messageRow.isFromMe == 1,
            isErrored: messageRow.error != 0,
            threadID: messageRow.threadID,
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
        if appleDateIsTruthy(dates.retracted) || messageRow.wasDetonated == 1 {
            message.isDeleted = true
        }
        if messageRow.isRead == 1 {
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

    private func applyBalloonProps(
        to message: inout MessageDraft,
        header: inout MessagePatch,
        bundleKind: BalloonBundleKind?
    ) {
        func setHeading(_ heading: String, attachment: PlatformSDK.Attachment?) {
            header.textHeading = heading
            if let attachment {
                message.attachments = [attachment]
            }
        }

        guard let bundleKind else {
            return
        }
        switch bundleKind {
        case .digitalTouch:
            setHeading("Digital Touch Message", attachment: digitalTouchAttachment())
        case .handwriting:
            setHeading("Handwritten Message", attachment: handwritingAttachment())
        case .businessExtension:
            header.textHeading = "Business Chat Extension"
        case .gamePigeon:
            if (message.textHeading ?? "").isEmpty {
                header.textHeading = gamePigeonDisplayName
            }
        default:
            break
        }
    }

    private func digitalTouchAttachment() -> PlatformSDK.Attachment? {
        guard let data = messageRow.payloadData,
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
            srcURL: digitalTouchAssetURL(uuid: uuid, rowID: messageRow.rowID)
        )
    }

    private func handwritingAttachment() -> PlatformSDK.Attachment? {
        guard let data = messageRow.payloadData,
              let uuid = stringFromDataSlice(data, start: uuidStart, length: uuidLength),
              isUUID(uuid) else {
            return nil
        }
        return PlatformSDK.Attachment(
            id: uuid,
            type: .img,
            isGif: true,
            srcURL: handwritingAssetURL(uuid: uuid, rowID: messageRow.rowID)
        )
    }

    private func applySiriFooter(summaryInfo: JSONObject, footer: inout MessagePatch) {
        guard !summaryInfo.isEmpty, summaryInfo.string("amsa") == "com.apple.siri" else {
            return
        }
        footer.textFooter = "Sent with Siri"
    }

    private func applyThreadOriginator(to header: inout MessagePatch) {
        guard let originatorGUID = messageRow.threadOriginatorGUID, !originatorGUID.isEmpty else {
            return
        }
        let rawPartIndex = messageRow.threadOriginatorPart?
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
        if messageRow.attributedBody == nil, summaryInfo.hasValue("rp"), summaryInfo.dictionary("otr") != nil {
            return [.unsent(index: 0, originalPart: nil, end: 0)]
        }
        let text = removeObjectReplacementCharacter(messageRow.text ?? "")
            .replacingOccurrences(of: imessageExtensionCharacter, with: "")
        return [.text(index: 0, originalPart: nil, end: 0, text: text, attributes: nil)]
            + attachments.enumerated().map { offset, attachment in
                .attachment(index: offset + 1, originalPart: nil, end: 0, attachmentID: attachment.id)
            }
    }

    private func shouldAddSubjectInline(_ subject: String?, to parts: [MessagePart]) -> Bool {
        guard let subject,
              !subject.isEmpty,
              let firstPart = parts.first,
              case let .text(_, _, _, text, _) = firstPart else {
            return false
        }
        return !text.isEmpty
    }

    private func makeMessages(
        from parts: [MessagePart],
        partialMessage: MessageDraft,
        partialHeader: MessagePatch,
        partialFooter: MessagePatch,
        attachmentsByID: [String: PlatformSDK.Attachment],
        editHistory: [Int: [PlatformSDK.MessageEdit]]
    ) -> [MessageDraft] {
        parts.enumerated().map { partIndex, part in
            var message = partialMessage
            if parts.count > 1 {
                message.extra["part"] = part.index
            }
            let partEditHistory = editHistoryForPart(part, partCount: parts.count, editHistory: editHistory)
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
            if !part.isUnsent {
                message.editHistory = editHistoryExcludingCurrentMessage(partEditHistory, currentMessage: message)
            }
            return message
        }
    }

    private func apply(_ part: MessagePart, to message: inout MessageDraft, attachmentsByID: [String: PlatformSDK.Attachment]) {
        switch part {
        case let .text(_, _, _, text, attributes):
            let isAttachmentPlaceholder = message.attachments?.isEmpty == false
                && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isAttachmentPlaceholder, !text.isEmpty || message.text == nil {
                message.text = text
            }
            if let attributes {
                message.textAttributes = attributes
            }
        case let .attachment(_, _, _, attachmentID):
            if let attachment = attachmentsByID[attachmentID] {
                message.attachments = [attachment]
            }
        case .unsent:
            message.isAction = true
            message.parseTemplate = true
            message.editedTimestamp = nil
            // Clear rich fields so update patches replace stale merged state.
            message.attachments = []
            message.tweets = []
            message.links = []
            message.reactions = []
            message.editHistory = []
            message.text = "{{sender}} unsent a message"
        }
    }

    private func unsupportedBalloonPlaceholder(
        partialMessage: MessageDraft,
        payloadData: Any?,
        bundleKind: BalloonBundleKind?,
        linkedMessageID: PlatformSDK.MessageID?
    ) -> MessageDraft? {
        guard let bundleID = messageRow.balloonBundleID,
              bundleKind == nil else {
            return nil
        }
        var message = actionMessage(
            partialMessage,
            text: unsupportedBalloonText(bundleID: bundleID, payloadData: payloadData)
        )
        message.linkedMessageID = linkedMessageID
        return message
    }

    private func unsupportedBalloonText(bundleID: String, payloadData: Any?) -> String {
        guard let appName = unsupportedBalloonAppName(bundleID: bundleID, payloadData: payloadData) else {
            return actionText("sent an unsupported iMessage app message")
        }
        return actionText("sent a message from \(appName)")
    }

    private func unsupportedBalloonAppName(bundleID: String, payloadData: Any?) -> String? {
        if let payloadData,
           let payloadAppName = balloonPayloadAppName(from: payloadData) {
            return payloadAppName
        }
        if let appName = unsupportedBalloonBundleNames[bundleID] {
            return appName
        }
        return nil
    }

    private func balloonPayloadAppName(from payloadData: Any) -> String? {
        pluginPayloadAppName(unwrapDictionary(payloadData)?.string("an"))
    }
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

extension Mapper {
    fileprivate func shouldKeepMessage(_ message: MessageDraft) -> Bool {
        if let attachments = message.attachments, !attachments.isEmpty {
            return true
        }
        if let tweets = message.tweets, !tweets.isEmpty {
            return true
        }
        if let links = message.links, !links.isEmpty {
            return true
        }
        if let iframeURL = message.iframeURL, !iframeURL.isEmpty {
            return true
        }
        if let text = message.text, !text.isEmpty {
            return true
        }
        return !(message.textHeading ?? "").isEmpty
    }

    func actionText(_ action: String) -> String {
        let actor = messageRow.isFromMe == 1 ? "You" : "{{sender}}"
        return "\(actor) \(action)"
    }

    func actionMessage(
        _ inputMessage: MessageDraft,
        text: String,
        isHidden: Bool? = nil
    ) -> MessageDraft {
        var message = inputMessage
        message.isAction = true
        message.isHidden = isHidden
        message.parseTemplate = true
        message.textAttributes = nil
        message.textHeading = nil
        message.textFooter = nil
        message.text = text
        return message
    }
}

extension Mapper {
    init(
        messageRow: JSONObject,
        attachmentRows: [JSONObject],
        reactionRows: [JSONObject],
        currentUserID: String,
        accountID: String
    ) throws {
        try self.init(
            messageRow: MappedMessageRow(object: messageRow),
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
