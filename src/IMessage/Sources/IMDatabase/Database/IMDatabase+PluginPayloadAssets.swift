import Foundation
import SQLite

private let digitalTouchBalloonBundleID = "com.apple.DigitalTouchBalloonProvider"
private let handwritingBalloonBundleID = "com.apple.Handwriting.HandwritingProvider"

private enum PluginPayloadColumn {
    static let payloadData = 0
    static let messageGUID = 1
    static let isFromMe = 2
}

extension IMDatabase {
    public func digitalTouchPayload(rowID: Int) throws -> (payloadData: Data, isFromMe: Bool)? {
        try pluginPayload(rowID: rowID, bundleID: digitalTouchBalloonBundleID).map {
            (payloadData: $0.payloadData, isFromMe: $0.isFromMe)
        }
    }

    public func handwritingPayload(rowID: Int) throws -> (payloadData: Data, messageGUID: String, isFromMe: Bool)? {
        try pluginPayload(rowID: rowID, bundleID: handwritingBalloonBundleID)
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
            guard let payloadData = try row[PluginPayloadColumn.payloadData].optional(Data.self) else {
                return nil
            }
            return try (
                payloadData: payloadData,
                messageGUID: row[PluginPayloadColumn.messageGUID].expect(String.self),
                isFromMe: row[PluginPayloadColumn.isFromMe].expectConverting(Int.self) != 0
            )
        }.first
    }
}
