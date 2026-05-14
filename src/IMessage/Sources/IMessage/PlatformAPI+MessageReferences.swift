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

    public func resolveLatestMessageReference(threadID: String? = nil, offset: Int = 0) async throws -> MessageReference? {
        try await runDBQuery { db, _, _ in
            try Self.resolveLatestMessageReference(db: db, threadID: threadID, offset: offset)
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
        guard let msgRow = try db.mappedMessageRow(guid: messageGUID) else {
            return nil
        }
        guard let threadID = try msgRow.threadID ?? db.threadIDForMessage(rowID: msgRow.rowID) else {
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
        offset: Int
    ) throws -> MessageReference? {
        guard offset >= 0 else { return nil }
        let resolvedOriginalThreadID = try publicThreadID.map { try originalThreadID(db: db, $0) }
        guard let msgRow = try db.mappedLatestVisibleMessageRow(in: resolvedOriginalThreadID, offset: offset) else {
            return nil
        }
        guard let threadID = try resolvedOriginalThreadID ?? msgRow.threadID ?? db.threadIDForMessage(rowID: msgRow.rowID) else {
            return nil
        }
        return MessageReference(
            threadID: Hasher.thread.tokenizeRemembering(pii: threadID),
            messageID: msgRow.guid
        )
    }
}
