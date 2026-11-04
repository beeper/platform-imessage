public extension IMDatabase {
    func accountLogins() throws -> [String] {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT DISTINCT account_login
        FROM chat
        """)

        try statement.reset()

        return try statement.compactMapRowsUntilDone { row in
            try row[0].optional(String.self)
        }
    }

    func recentDestinationCallerIDs(withinNanoseconds window: Int64) throws -> [String] {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT DISTINCT destination_caller_id
        FROM message
        WHERE date >= (SELECT MAX(date) FROM message) - ?
            AND destination_caller_id IS NOT NULL
            AND destination_caller_id != ''
        """)

        try statement.reset()
        try statement.bind(window)

        return try statement.compactMapRowsUntilDone { row in
            try row[0].optional(String.self)
        }
    }
}
