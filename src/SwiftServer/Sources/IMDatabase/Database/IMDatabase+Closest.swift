import Foundation
import Logging

private let log = Logger(swiftServerLabel: "imdb.closest")

public struct ClosestMessagePart {
    public var closestSelectable: Message.Part
    public var offsetFromTarget: Int
}

//  This logic is incredibly subtle for several reasons.                              +------------------------+
//                                                                               9:24 | message DEADBEEF…      |
//  Each iMessage message is made up of an arbitrarily long sequence of               |                        |
//  "parts". Parts can be arbitrarily interleaved with regular text, and they         | - - - - - - - - - - - +|
//  usually represent attachments. Within the attributed string, they are             || part 0                |  ^
//  represented with U+FFFC OBJECT REPLACEMENT CHARACTER. For example, on macOS       | - - - - - - - - - - - +|  |
//  I can compose an iMessage like so: "TAke a look, y'all: ￼" Imagine that           | - - - - - - - - - - - +|  |
//  I've attached some image at the end. The internal representation of this          || part 1                |  |
//  looks something like:                                                             | - - - - - - - - - - - +|  |
//                                                                                    +------------------------+  |
//  Part 1: [0,  20)                                                                  +------------------------+  |
//  Part 2: [20, 21) (attribute GUID: "ABCDEF...")                               9:26 | message ABCDEF…        |  |
//                                                                                    |                        |  |
//  Part 2 is the "image" that I've attached, which also has a GUID attribute         | - - - - - - - - - - - +|  |  +------------+
//  attached that points back to the corresponding row within the `attachment`        || part 0                |  |  |  "BEFORE"  |
//  SQLite table. This lets the app render everything correctly.                      | - - - - - - - - - - - +|  |  +------------+
//                                                                                    |+----------------------+|  |
//  Where this gets complicated is that, in the Messages app, each part is            || part 1 *our target*  ||--|
//  rendered as its own bubble. _Each part is able to be individually unsent,         |+----------------------+|  |
//  edited, and reacted to._ In effect, this means that you are able to edit,         | - - - - - - - - - - - +|  |
//  unsend, or react to disparate fragments of a message, addressing any part         || part 2                |  |
//  individually. Naturally, unsending a message part will cause a message's          | - - - - - - - - - - - +|  |
//  part indices to become discontinuous. When a part of a message is unsent or       +------------------------+  |
//  edited, the `otr` field in the message's "summary info" can be used to            +------------------------+  |
//  recover the original structure before any destructive modifications took     9:28 | message CAFEFOOD…      |  |  +------------+
//  place. Handling message parts fluently is key to correct behavior.                |                        |  |  |  "AFTER"   |
//                                                                                    | - - - - - - - - - - - +|  |  +------------+
//  (Logically, clients shouldn't have to know what a part is. We just map each       || part 0                |  v
//  part to their own message. This means that a single iMessage message can be       | - - - - - - - - - - - +|
//  backed by multiple messages on Beeper.) Naturally, we need to bridge              +------------------------+
//  essential operations (such as replying, reactions, etc.) that are possible
//  for each message part. This is done by opening a deep link with the message
//  GUID (_not_ including the part, which we can't specify), and committing the
//  usual crimes (puppeting the app with the accessibility APIs).
//
//  HOWEVER, for whatever reason, certain types of message parts cannot be
//  properly selected by deep links in this manner. Notably: attachments,
//  messages consisting entirely of emoji (jumbo), and probably more. _This_,
//  ultimately, is what this logic is intended to circumvent. If the user
//  wishes to address a message part that we cannot select through ordinary
//  means, we scan vertically for the closest selectable message part. This
//  includes sibling parts within the target message itself, as well as other
//  messages. If we find one, we make note of the index offset, open the
//  appropriate deep link, and correct accordingly.
//
//  With a message selected, we are able to orient ourselves and pivot to the
//  actual message part the user actually wanted to interact with via the
//  offset. A subtlety here is that banners and other minutiae dynamically
//  inserted into the transcript (such as "Today 1:54 PM" and group membership
//  events) need to be removed before indexing.

public extension IMDatabase {
    func findClosestSelectablePart(
        from target: Message.Part, parentMessage message: Message, in chat: GUID<Chat>
    ) throws -> ClosestMessagePart? {
        guard !target.isSelectable else {
            log.warning(
                "tried to find closest selectable part relative to part that's already selectable, returning as-is"
            )
            return ClosestMessagePart(closestSelectable: target, offsetFromTarget: 0)
        }

        let parts = message.parts
        guard let targetPartOffset = parts.firstIndex(of: target) else {
            // misuse of this API
            log.error("parent message of target part does not contain the target part in question")
            return nil
        }

        guard let targetDate = message.date else {
            log.error("target's parent message has no date")
            // rare/impossible?
            return nil
        }

        func findFirstSelectablePart(in parts: some Collection<Message.Part>, scanningUpwards: Bool)
            -> ClosestMessagePart?
        {
            guard let firstSelectable = parts.enumerated().first(where: \.element.isSelectable)
            else {
                return nil
            }
            let direction = scanningUpwards ? "<up>" : "<down>"
            let targetRelativeOffset =
                targetPartOffset + (firstSelectable.offset + 1) * (scanningUpwards ? -1 : 1)
#if DEBUG
            log.debug(
                """
                FOUND closest selectable scanning \(direction), \
                offset within fetch result: \(firstSelectable.offset), \
                offset relative to target: \(targetRelativeOffset)
                """)
#endif
            return ClosestMessagePart(
                closestSelectable: firstSelectable.element, offsetFromTarget: targetRelativeOffset
            )
        }

        do {
            let searchRange = 15

            // Since we intend to find a selectable part that's as close to the target as possible, reverse the part ordering
            // for the messages above our target so that we _always_ move "upwards". Otherwise, we'd enumerate message parts
            // by their normal ordering within each message.
            let messagesBefore = try messages(
                in: chat, filter: .before(targetDate), order: .newestFirst, limit: searchRange
            )
            let partsBeforeWithinSelf = parts.filter { $0.index < target.index }.reversed()
            let partsBefore =
                Array(partsBeforeWithinSelf) + messagesBefore.flatMap { $0.parts.reversed() }
            if let hit = findFirstSelectablePart(in: partsBefore, scanningUpwards: true) {
                return hit
            }

            let messagesAfter = try messages(
                in: chat, filter: .after(targetDate), order: .oldestFirst, limit: searchRange
            )
            let partsAfterWithinSelf = parts.filter { $0.index > target.index }
            let partsAfter = Array(partsAfterWithinSelf) + messagesAfter.flatMap(\.parts)
            if let hit = findFirstSelectablePart(in: partsAfter, scanningUpwards: false) {
                return hit
            }

            log.warning(
                "couldn't find a closest selectable message part! (before: \(messagesBefore.count), after: \(messagesAfter.count))"
            )
        }

        return nil
    }
}

private extension Message {
    var compactDebuggingDescription: String {
        let content =
            (attributedBody?.unwrappingSensitiveData().string) ?? text?.unwrappingSensitiveData()
        let quotedContent = content.map { "\"\($0)\"" }
        return
            "#\(id) \(guid): \(quotedContent, default: "<no text>") @\(date.formattedForDebugging)"
    }
}

private extension Message {
    var firstSelectablePart: (offset: Int, element: Part)? {
        for (index, part) in parts.enumerated() where part.isSelectable {
            return (index, part)
        }
        return nil
    }
}

private extension Collection<Message> {
    var formattedForDebugging: String {
        "\n"
            + enumerated().map { index, message in
                let markerLength = 5
                let position = "\(index + 1)/\(count)".padding(
                    toLength: markerLength, withPad: " ", startingAt: 0
                )
                let indent = String(repeating: " ", count: markerLength)

                var lines = ["\(index + 1)/\(count) \(message.compactDebuggingDescription)"]
                let parts = message.parts
                for (index, part) in parts.enumerated() {
                    let range = part.rangeWithinParentAttributedBody
                    let emoji = part.replacedWithObject ? "🖼️ " : ""
                    let tags = [
                        part.isSelectable ? "selectable" : nil,
                        {
                            guard let guid = part.attachmentGUID else {
                                return nil
                            }
                            return "[attachment GUID: \(guid)"
                        }(),
                    ].compactMap(\.self)
                    lines.append(
                        "\(indent) part #\(part.index): \(emoji)@\(range.location)..<\(range.location + range.length) \(tags)"
                    )
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
    }
}

extension Message.Part {
    var isSelectable: Bool {
        let body = attributedSubstring.string
        let hasText = body.nonEmpty != nil
        guard hasText else {
#if DEBUG
            log.debug("\(parentMessageGUID)/\(index): has no text, or is empty")
#endif
            return false
        }

        let onlyConsistsOfWhitespaceOrEmojis = body.allSatisfy { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy(\.properties.isEmoji)
        }
        guard !onlyConsistsOfWhitespaceOrEmojis else {
#if DEBUG
            log.debug("\(parentMessageGUID)/\(index): only consists of whitespace or emojis")
#endif
            return false
        }

        guard attachmentGUID == nil else {
#if DEBUG
            log.debug("\(parentMessageGUID)/\(index): is an attachment")
#endif
            return false
        }

#if DEBUG
        log.debug("\(parentMessageGUID)/\(index): SELECTABLE!")
#endif
        return true
    }
}
