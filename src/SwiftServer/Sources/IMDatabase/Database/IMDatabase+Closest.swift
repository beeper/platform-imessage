import Logging

private let log = Logger(swiftServerLabel: "imdb.closest")

public struct ClosestMessage {
    public var selectable: Message
    public var relativeOffsetFromTarget: Int
}

public extension IMDatabase {
    func findSelectableMessage(closestTo target: Message, in chat: GUID<Chat>) throws -> ClosestMessage? {
        guard !target.isSelectable else {
            log.debug("target is already selectable")
            return ClosestMessage(selectable: target, relativeOffsetFromTarget: 0)
        }

        let limit = 15
        guard let targetDate = target.date else {
            log.error("target message has no date?")
            // rare
            return nil
        }

        let messagesBefore = try messages(in: chat, filter: .before(targetDate), order: .newestFirst, limit: limit)
#if DEBUG
        log.debug("messages BEFORE: \(messagesBefore.formattedForDebugging)")
#endif
        if let (offset, selectable) = messagesBefore.firstSelectable {
#if DEBUG
            log.debug("HIT with a message BEFORE")
#endif
            return ClosestMessage(selectable: selectable, relativeOffsetFromTarget: -(offset + 1))
        } else {
            log.warning("no messages before (\(messagesBefore.count)) were selectable")
        }

        let messagesAfter = try messages(in: chat, filter: .after(targetDate), order: .oldestFirst, limit: limit)
#if DEBUG
        log.debug("messages AFTER: \(messagesAfter.formattedForDebugging)")
#endif
        if let (offset, selectable) = messagesAfter.firstSelectable {
#if DEBUG
            log.debug("HIT with a message AFTER")
#endif
            return ClosestMessage(selectable: selectable, relativeOffsetFromTarget: offset + 1)
        } else {
            log.warning("no messages after (\(messagesAfter.count)) were selectable")
        }

        return nil
    }
}

private extension Collection<Message> {
    var firstSelectable: (offset: Int, element: Message)? {
        enumerated().filter(\.element.isSelectable).first
    }

    var formattedForDebugging: String {
        var lines = [String]()
        for (index, message) in enumerated() {
            let content = (message.attributedBody?.unwrappingSensitiveData().string) ?? message.text?.unwrappingSensitiveData()
            let quotedContent = content.map { "\"\($0)\"" }
            lines.append("\(index + 1)/\(count) #\(message.id) \(message.guid): \(quotedContent, default: "<no text>") @\(message.date.formattedForDebugging)")
        }
        return lines.joined(separator: "\n")
    }
}

extension Message {
    var isSelectable: Bool {
        // TODO: check for no part
        // TODO: check for no links

        let content = (attributedBody?.unwrappingSensitiveData().string) ?? text?.unwrappingSensitiveData()
        let hasText = content?.nonEmpty != nil
        guard hasText else {
#if DEBUG
            log.debug("\(id)/\(guid): has no text, or is empty - \(content) \(date.formattedForDebugging)")
#endif
            return false
        }

        let onlyConsistsOfWhitespaceOrEmojis = content.map {
            $0.allSatisfy { character in
                character.isWhitespace || character.unicodeScalars.allSatisfy(\.properties.isEmoji)
            }
        } ?? false
        guard !onlyConsistsOfWhitespaceOrEmojis else {
#if DEBUG
            log.debug("\(id)/\(guid): only consists of whitespace or emojis - \(content) \(date.formattedForDebugging)")
#endif
            return false
        }

        let definitelyHasNoAttachments = attachments?.isEmpty == true
        guard definitelyHasNoAttachments else {
#if DEBUG
            log.debug("\(id)/\(guid): \(attachments == nil ? "attachments dehydrated" : "has \(attachments!.count) attachment(s)") - \(content) \(date.formattedForDebugging)")
#endif
            return false
        }

        return true
    }
}
