import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

extension Mapper {
    func decodeAttributedMessageParts(summaryInfo: JSONObject) -> [MessagePart] {
        guard let data = messageRow.attributedBody,
              let decoded = try? AttributedBodyDecoder.fragments(from: data) else {
            return []
        }
        return decodeMessageParts(fragments: decoded, messageSummaryInfo: summaryInfo)
    }

    func decodeMessageParts(
        fragments: [AttributedBodyDecoder.Fragment],
        messageSummaryInfo: JSONObject
    ) -> [MessagePart] {
        var parts = [MessagePart]()
        var handledDeletedParts = [Int]()
        var lastSeenPart: Int?
        let deletedParts = messageSummaryInfo.array("rp").compactMap { ($0 as? NSNumber)?.intValue }

        for fragment in fragments {
            let attributes = fragment.attributes
            let attachmentID = attributes["__kIMFileTransferGUIDAttributeName"] as? String
            let partNumber = attributes["__kIMMessagePartAttributeName"].map { "\($0)" }.flatMap(Int.init)

            if let partNumber {
                if let lastSeenPart,
                   lastSeenPart != 0,
                   partNumber > lastSeenPart + 1,
                   deletedParts.contains(partNumber - 1) {
                    let unsentParts = partNumber - lastSeenPart - 1
                    let startingIndexOfSent = fragment.scalarRange.lowerBound + unsentParts
                    for unsentIndex in (startingIndexOfSent - unsentParts) ..< startingIndexOfSent {
                        let unsentPart = partNumber - (startingIndexOfSent - unsentIndex)
                        parts.append(.unsent(index: parts.count, originalPart: unsentPart, end: unsentIndex + 1))
                        handledDeletedParts.append(unsentPart)
                    }
                }
                lastSeenPart = partNumber
            }

            let from = fragment.scalarRange.lowerBound + handledDeletedParts.count
            let end = fragment.scalarRange.upperBound + handledDeletedParts.count

            if let attachmentID {
                parts.append(.attachment(index: parts.count, originalPart: partNumber, end: end, attachmentID: attachmentID))
            } else {
                appendTextFragment(fragment, partNumber: partNumber, from: from, end: end, to: &parts)
            }
        }

        appendTrailingUnsentParts(to: &parts, deletedParts: deletedParts, handledDeletedParts: handledDeletedParts)
        normalizeEntityRangesByPart(in: &parts)
        return parts
    }

    func mapTextEntity(_ attr: JSONObject, from: Int, to: Int) -> PlatformSDK.TextEntity? {
        let bold = attr.stringifying("__kIMTextBoldAttributeName") == "1" ? true : nil
        let italic = attr.stringifying("__kIMTextItalicAttributeName") == "1" ? true : nil
        let underline = attr.stringifying("__kIMTextUnderlineAttributeName") == "1" ? true : nil
        let strikethrough = attr.stringifying("__kIMTextStrikethroughAttributeName") == "1" ? true : nil
        let link = attr.stringifying("__kIMLinkAttributeName").flatMap(\.nonEmpty)
        let mentionedUser = (attr["__kIMMentionConfirmedMention"] as? String).map { PlatformSDK.MentionedUser(id: $0) }
        guard bold != nil || italic != nil || underline != nil || strikethrough != nil || link != nil || mentionedUser != nil else {
            return nil
        }
        return PlatformSDK.TextEntity(
            from: from,
            to: to,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough,
            link: link,
            mentionedUser: mentionedUser
        )
    }

    private func appendTextFragment(
        _ fragment: AttributedBodyDecoder.Fragment,
        partNumber: Int?,
        from: Int,
        end: Int,
        to parts: inout [MessagePart]
    ) {
        if partNumber == nil || parts.isEmpty || !parts[parts.count - 1].isText {
            parts.append(.text(index: parts.count, originalPart: partNumber, end: 0, text: "", attributes: nil))
        }
        guard case let .text(index, originalPart, _, existingText, existingAttributes) = parts[parts.count - 1] else {
            return
        }

        let text = existingText + String(fragment.text).replacingOccurrences(of: imessageExtensionCharacter, with: "")
        var attributesForPart = existingAttributes
        if let entity = mapTextEntity(fragment.attributes, from: from, to: end) {
            var entities = attributesForPart?.entities ?? []
            entities.append(entity)
            attributesForPart = PlatformSDK.TextAttributes(entities: entities)
        }
        parts[parts.count - 1] = .text(index: index, originalPart: originalPart, end: end, text: text, attributes: attributesForPart)
    }

    private func appendTrailingUnsentParts(
        to parts: inout [MessagePart],
        deletedParts: [Int],
        handledDeletedParts: [Int]
    ) {
        let handledDeletedParts = Set(handledDeletedParts)
        let trailingDeletedParts = deletedParts.filter { !handledDeletedParts.contains($0) }
        guard !trailingDeletedParts.isEmpty else {
            return
        }
        for deletedPart in trailingDeletedParts {
            parts.append(.unsent(index: parts.count, originalPart: deletedPart, end: parts.count + 1))
        }
    }

    private func normalizeEntityRangesByPart(in parts: inout [MessagePart]) {
        guard parts.count > 1 else {
            return
        }
        for index in 1 ..< parts.count {
            guard case let .text(partIndex, originalPart, end, text, attributes) = parts[index],
                  case let previous = parts[index - 1],
                  let entities = attributes?.entities else {
                continue
            }
            let adjustedEntities = entities.map { $0.offsetting(by: -previous.end) }
            parts[index] = .text(index: partIndex, originalPart: originalPart, end: end, text: text, attributes: PlatformSDK.TextAttributes(entities: adjustedEntities))
        }
    }
}
