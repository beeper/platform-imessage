import GRDB

public extension IMDatabase {
    func accountLogins() throws -> [String] {
        try read { db in
            try Row.fetchAll(db, sql: """
            SELECT DISTINCT account_login
            FROM chat
            """).compactMap { $0[0] as String? }
        }
    }
}
