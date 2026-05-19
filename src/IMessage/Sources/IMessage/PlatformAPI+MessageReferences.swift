import IMDatabase

extension PlatformAPI {
    public struct MessageReference: Sendable {
        public let threadID: String
        public let messageID: String

        public init(threadID: String, messageID: String) {
            self.threadID = threadID
            self.messageID = messageID
        }
    }

    public func resolveMessageReference(messageID: String) async throws -> MessageReference? {
        try await runDBQuery { db, _, _ in
            try Self.resolveMessageReference(db: db, messageID: messageID)
        }
    }

    public func resolveLatestMessageReference(threadID: String? = nil, offset: Int = 0, ownedOnly: Bool = false) async throws -> MessageReference? {
        try await runDBQuery { db, _, _ in
            try Self.resolveLatestMessageReference(db: db, threadID: threadID, offset: offset, ownedOnly: ownedOnly)
        }
    }

    public func lookupExistingThreadGUIDs(guids: [String]) async throws -> [String] {
        try await runDBQuery { db, _, _ in
            try db.mappedExistingChatGUIDs(guids: guids)
        }
    }

    nonisolated static func resolveMessageReference(
        db: IMDatabase,
        messageID: String
    ) throws -> MessageReference? {
        let messageGUID = messageGUID(fromID: messageID)
        guard let messageRow = try db.mappedMessageRow(guid: messageGUID) else {
            return nil
        }
        guard let threadID = try messageRow.threadID ?? db.threadIDForMessage(rowID: messageRow.rowID) else {
            return nil
        }
        return MessageReference(
            threadID: Hasher.thread.tokenizeRemembering(pii: threadID),
            messageID: messageID
        )
    }

    nonisolated static func resolveLatestMessageReference(
        db: IMDatabase,
        threadID publicThreadID: String?,
        offset: Int,
        ownedOnly: Bool = false
    ) throws -> MessageReference? {
        guard offset >= 0 else { return nil }
        let resolvedOriginalThreadID = try publicThreadID.map { try originalThreadID(db: db, $0) }
        guard let messageRow = try db.mappedLatestVisibleMessageRow(in: resolvedOriginalThreadID, offset: offset, ownedOnly: ownedOnly) else {
            return nil
        }
        guard let threadID = try resolvedOriginalThreadID ?? messageRow.threadID ?? db.threadIDForMessage(rowID: messageRow.rowID) else {
            return nil
        }
        return MessageReference(
            threadID: Hasher.thread.tokenizeRemembering(pii: threadID),
            messageID: messageRow.guid
        )
    }
}
