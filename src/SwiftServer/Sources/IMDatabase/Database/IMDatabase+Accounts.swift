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
}
