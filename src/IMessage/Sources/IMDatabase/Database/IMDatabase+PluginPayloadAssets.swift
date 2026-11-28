import Foundation
import IMessageCore
import SQLite

extension IMDatabase {
    public func digitalTouchPayload(rowID: Int) throws -> (payloadData: Data, isFromMe: Bool)? {
        try pluginPayload(rowID: rowID, bundleID: BalloonBundleKind.digitalTouch.rawValue).map {
            (payloadData: $0.payloadData, isFromMe: $0.isFromMe)
        }
    }

    public func handwritingPayload(rowID: Int) throws -> (payloadData: Data, messageGUID: String, isFromMe: Bool)? {
        try pluginPayload(rowID: rowID, bundleID: BalloonBundleKind.handwriting.rawValue)
    }

    public func linkPreviewPayload(attachmentGUID: String) throws -> (filename: String, messageGUID: String, chatGUID: String)? {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT a.filename, m.guid, c.guid
        FROM attachment a
        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
        JOIN message m ON m.ROWID = maj.message_id
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE a.guid = ?
          AND m.balloon_bundle_id = ?
          AND a.filename IS NOT NULL
        LIMIT 1
        """).reset()
        try statement.bind(attachmentGUID, BalloonBundleKind.url.rawValue)

        return try statement.compactMapRowsUntilDone { row in
            try (
                filename: row[0].expect(String.self),
                messageGUID: row[1].expect(String.self),
                chatGUID: row[2].expect(String.self)
            )
        }.first
    }

    private func pluginPayload(
        rowID: Int,
        bundleID: String
    ) throws -> (payloadData: Data, messageGUID: String, isFromMe: Bool)? {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT payload_data, guid, is_from_me
        FROM message
        WHERE ROWID = ?
          AND balloon_bundle_id = ?
          AND payload_data IS NOT NULL
        LIMIT 1
        """).reset()
        try statement.bind(rowID, bundleID)

        return try statement.compactMapRowsUntilDone { row in
            guard let payloadData = try row[0].optional(Data.self) else {
                return nil
            }
            return try (
                payloadData: payloadData,
                messageGUID: row[1].expect(String.self),
                isFromMe: row[2].looseBool()
            )
        }.first
    }
}
