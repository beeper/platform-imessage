import SQLiteData

public extension IMDatabase {
    func accountLogins() throws -> [String] {
        try read { db in
            try fetchAllSQL(String?.self, db: db, sql: """
            SELECT DISTINCT account_login
            FROM chat
            """).compactMap(\.self)
        }
    }
}
