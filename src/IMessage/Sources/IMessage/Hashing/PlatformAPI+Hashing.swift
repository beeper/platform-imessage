import IMDatabase
import IMessageCore
import PlatformSDK

private let platformAPIHasWarmedThreadHasher = Protected(false)

extension PlatformAPI {
    nonisolated static func originalThreadID(db: IMDatabase, _ threadID: String) throws -> String {
        guard threadID.hasPrefix("imsg") else {
            return threadID
        }
        do {
            return try Hasher.thread.recoverOriginal(fromToken: threadID)
        } catch {
            let shouldWarm = platformAPIHasWarmedThreadHasher.withLock { hasWarmed in
                guard !hasWarmed else { return false }
                hasWarmed = true
                return true
            }
            if shouldWarm {
                for guid in try db.allThreadGUIDs() {
                    _ = Hasher.thread.tokenizeRemembering(pii: guid)
                }
            }
            return try Hasher.thread.recoverOriginal(fromToken: threadID)
        }
    }

    nonisolated static func mapAndHashMessages(
        msgRows: [MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [PlatformSDK.Message] {
        guard !msgRows.isEmpty else {
            return []
        }

        let attachmentRowsByMessageID = Dictionary(grouping: attachmentRows, by: \.msgRowID)
        let reactionRowsByMessageGUID = Dictionary(grouping: reactionRows, by: { parseAssociatedMessageTarget($0.associatedMessageGUID).messageGUID })

        return try msgRows.flatMap { msgRow -> [PlatformSDK.Message] in
            try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.rowID] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.guid] ?? [],
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
    }

    nonisolated static func mapAndHashMessagesByRowID(
        msgRows: [MappedMessageRow],
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [Int: [PlatformSDK.Message]] {
        guard !msgRows.isEmpty else {
            return [:]
        }

        let attachmentRowsByMessageID = Dictionary(grouping: attachmentRows, by: \.msgRowID)
        let reactionRowsByMessageGUID = Dictionary(grouping: reactionRows, by: { parseAssociatedMessageTarget($0.associatedMessageGUID).messageGUID })

        var messagesByRowID = [Int: [PlatformSDK.Message]]()
        for msgRow in msgRows {
            messagesByRowID[msgRow.rowID] = try mapAndHashMessage(
                msgRow: msgRow,
                attachmentRows: attachmentRowsByMessageID[msgRow.rowID] ?? [],
                reactionRows: reactionRowsByMessageGUID[msgRow.guid] ?? [],
                currentUserID: currentUserID,
                accountID: accountID
            )
        }
        return messagesByRowID
    }

    nonisolated static func mapAndHashMessage(
        msgRow: MappedMessageRow,
        attachmentRows: [MappedAttachmentRow],
        reactionRows: [MappedReactionMessageRow],
        currentUserID: String,
        accountID: String
    ) throws -> [PlatformSDK.Message] {
        let mapper = Mapper(
            msgRow: msgRow,
            attachmentRows: attachmentRows,
            reactionRows: reactionRows,
            currentUserID: currentUserID,
            accountID: accountID
        )
        let mapped = try mapper.mapMessage().filter { shouldKeepForAPI($0) }
        return mapped.map(hashMessage)
    }

    nonisolated static func hashMessage(_ message: PlatformSDK.Message) -> PlatformSDK.Message {
        copyMessage(
            message,
            senderID: Hasher.participant.tokenizeRemembering(pii: message.senderID),
            reactions: message.reactions?.map(hashReaction),
            threadID: message.threadID.map { Hasher.thread.tokenizeRemembering(pii: $0) }
        )
    }

    nonisolated static func hashReaction(_ reaction: PlatformSDK.MessageReaction) -> PlatformSDK.MessageReaction {
        PlatformSDK.MessageReaction(
            id: Hasher.participant.tokenizeRemembering(pii: reaction.id),
            reactionKey: reaction.reactionKey,
            imgURL: reaction.imgURL,
            participantID: Hasher.participant.tokenizeRemembering(pii: reaction.participantID),
            emoji: reaction.emoji
        )
    }

    nonisolated static func copyMessage(
        _ message: PlatformSDK.Message,
        senderID: PlatformSDK.UserID? = nil,
        reactions: [PlatformSDK.MessageReaction]? = nil,
        threadID: PlatformSDK.ThreadID? = nil
    ) -> PlatformSDK.Message {
        PlatformSDK.Message(
            id: message.id,
            timestamp: message.timestamp,
            editedTimestamp: message.editedTimestamp,
            expiresInSeconds: message.expiresInSeconds,
            forwardedCount: message.forwardedCount,
            forwardedFrom: message.forwardedFrom,
            senderID: senderID ?? message.senderID,
            text: message.text,
            textAttributes: message.textAttributes,
            textHeading: message.textHeading,
            textFooter: message.textFooter,
            attachments: message.attachments,
            tweets: message.tweets,
            links: message.links,
            iframeURL: message.iframeURL,
            reactions: reactions ?? message.reactions,
            seen: message.seen,
            isDelivered: message.isDelivered,
            isHidden: message.isHidden,
            isSender: message.isSender,
            isAction: message.isAction,
            isDeleted: message.isDeleted,
            isErrored: message.isErrored,
            parseTemplate: message.parseTemplate,
            linkedMessageThreadID: message.linkedMessageThreadID,
            linkedMessageID: message.linkedMessageID,
            linkedMessage: message.linkedMessage,
            action: message.action,
            buttons: message.buttons,
            behavior: message.behavior,
            accountID: message.accountID,
            threadID: threadID ?? message.threadID,
            sortKey: message.sortKey,
            cursor: message.cursor,
            extra: message.extra
        )
    }
}
