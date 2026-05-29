import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

struct MessageEditMetadata {
    // `editedOriginalPartKeys` is a superset of `historyByOriginalPartKey.keys`: it also covers
    // parts listed in `ep` and `ec` keys whose events produced no recoverable edits. The builder
    // (`parseEditMetadata`) inserts every history key into the set, so the two stay in sync.
    fileprivate let editedOriginalPartKeys: Set<Int>
    fileprivate let historyByOriginalPartKey: [Int: [PlatformSDK.MessageEdit]]

    func shouldApplyEditedTimestamp(
        to part: MessagePart,
        outputPartCount: Int
    ) -> Bool {
        guard outputPartCount > 1, !editedOriginalPartKeys.isEmpty else {
            return true
        }
        guard let originalPartKey = part.originalPart else {
            return false
        }
        return editedOriginalPartKeys.contains(originalPartKey)
    }

    func history(
        for part: MessagePart,
        outputPartCount: Int
    ) -> [PlatformSDK.MessageEdit]? {
        if let originalPartKey = part.originalPart {
            return historyByOriginalPartKey[originalPartKey]
        }

        guard outputPartCount == 1 else {
            return nil
        }

        return historyByOriginalPartKey[part.index]
            ?? historyByOriginalPartKey[0]
            ?? historyByOriginalPartKey[part.index - 1]
    }
}

extension Mapper {
    func parseEditMetadata(summaryInfo: JSONObject) -> MessageEditMetadata {
        var editedOriginalPartKeys = Set(summaryInfo.array("ep").compactMap { ($0 as? NSNumber)?.intValue })
        var historyByOriginalPartKey = [Int: [PlatformSDK.MessageEdit]]()

        if let editedEvents = summaryInfo.dictionary("ec") {
            for (rawOriginalPartKey, rawEvents) in editedEvents {
                guard let originalPartKey = Int(rawOriginalPartKey) else {
                    continue
                }
                editedOriginalPartKeys.insert(originalPartKey)

                guard let events = rawEvents as? [Any] else {
                    continue
                }
                let edits = events.compactMap(editHistoryEvent)
                if !edits.isEmpty {
                    historyByOriginalPartKey[originalPartKey] = edits
                }
            }
        }

        return MessageEditMetadata(
            editedOriginalPartKeys: editedOriginalPartKeys,
            historyByOriginalPartKey: historyByOriginalPartKey
        )
    }

    private func editHistoryEvent(_ rawEvent: Any) -> PlatformSDK.MessageEdit? {
        guard let event = rawEvent as? JSONObject,
              let seconds = event.int("d"),
              let timestamp = editHistoryTimestamp(seconds: seconds),
              let data = editHistoryBodyData(from: event["t"]) else {
            return nil
        }
        guard let fragments = try? AttributedBodyDecoder.fragments(from: data) else {
            return PlatformSDK.MessageEdit(timestamp: timestamp)
        }

        var textFragments = [String]()
        var entities = [PlatformSDK.TextEntity]()
        for fragment in fragments {
            let fragmentText = String(fragment.text).replacingOccurrences(of: imessageExtensionCharacter, with: "")
            textFragments.append(fragmentText)
            if let entity = mapTextEntity(
                fragment.attributes,
                from: fragment.scalarRange.lowerBound,
                to: fragment.scalarRange.upperBound
            ) {
                entities.append(entity)
            }
        }

        let text = textFragments.joined()
        return PlatformSDK.MessageEdit(
            timestamp: timestamp,
            text: text.isEmpty ? nil : text,
            textAttributes: entities.isEmpty ? nil : PlatformSDK.TextAttributes(entities: entities)
        )
    }

    private func editHistoryTimestamp(seconds: Int) -> Int64? {
        let seconds = Int64(seconds)
        let (millisecondsSinceReferenceDate, multiplicationOverflowed) =
            seconds.multipliedReportingOverflow(by: 1_000)
        guard !multiplicationOverflowed else {
            return nil
        }

        let (timestamp, additionOverflowed) =
            millisecondsSinceReferenceDate.addingReportingOverflow(coreFoundationReferenceDateMilliseconds)
        guard !additionOverflowed else {
            return nil
        }
        return timestamp
    }

    private func editHistoryBodyData(from value: Any?) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return data as Data
        }
        guard let string = value as? String else {
            return nil
        }
        return dataURLPayload(from: string).flatMap { Data(base64Encoded: $0) }
    }

    func editHistoryExcludingCurrentMessage(
        _ editHistory: [PlatformSDK.MessageEdit]?,
        currentMessage: MessageDraft
    ) -> [PlatformSDK.MessageEdit]? {
        guard var editHistory else {
            return nil
        }

        var currentEditIndex: Int?
        var matchingBodyIndex: Int?
        for index in editHistory.indices.reversed() {
            let edit = editHistory[index]
            guard isSameMessageBody(edit, currentMessage: currentMessage) else {
                continue
            }
            if edit.timestamp == currentMessage.editedTimestamp {
                currentEditIndex = index
                break
            }
            matchingBodyIndex = matchingBodyIndex ?? index
        }

        if let index = currentEditIndex ?? matchingBodyIndex {
            editHistory.remove(at: index)
        }
        return editHistory.isEmpty ? nil : editHistory
    }

    private func isSameMessageBody(
        _ edit: PlatformSDK.MessageEdit,
        currentMessage: MessageDraft
    ) -> Bool {
        edit.text == currentMessage.text
            && textAttributesEqual(edit.textAttributes, currentMessage.textAttributes)
    }

    private func textAttributesEqual(
        _ lhs: PlatformSDK.TextAttributes?,
        _ rhs: PlatformSDK.TextAttributes?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return NSDictionary(dictionary: lhs.jsonObject).isEqual(to: rhs.jsonObject)
        default:
            return false
        }
    }
}
