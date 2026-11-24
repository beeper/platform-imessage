import Foundation
import SQLite3
@testable import SQLite

/// The per-release `chat.db` schema dumps in `schemas/`, for building test databases.
enum ChatDatabaseSchema {
    static let oldest = "11.0.1-20B29"
    static let monterey = "12.6-21G115"
    static let sequoia = "15.6.1-24G90"
    static let tahoe = "26.4.1-25E253"
    static let newest = "27.2.1-26B131"

    /// Creates the tables, indexes and triggers of `schema` in an empty database.
    static func create(_ schema: String, in database: Database) throws {
        try database.executeScript(sqlWithoutEscaping: String(contentsOf: url(of: schema), encoding: .utf8))
        // The triggers call this function, which only Messages' own process registers.
        try database.createNoopFunction(name: "verify_chat", argumentCount: 1)
    }

    private static func url(of schema: String) -> URL {
        // .../platform-imessage/src/IMessage/Sources/IMessageTests/Support/<this file>
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 {
            repositoryRoot.deleteLastPathComponent()
        }
        return repositoryRoot.appendingPathComponent("schemas/\(schema).sql")
    }
}

private extension Database {
    func executeScript(sqlWithoutEscaping sql: String) throws {
        try sql.withCString { ptr in
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                if let errorMessage {
                    sqlite3_free(errorMessage)
                }
            }

            let result = sqlite3_exec(connection, ptr, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                throw SQLiteError(code: result)
            }
        }
    }

    func createNoopFunction(name: String, argumentCount: Int32) throws {
        let result = sqlite3_create_function_v2(
            connection,
            name,
            argumentCount,
            SQLITE_UTF8,
            nil,
            { context, _, _ in sqlite3_result_null(context) },
            nil,
            nil,
            nil
        )
        try SQLiteError.check(result)
    }
}
