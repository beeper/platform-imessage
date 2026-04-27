import SQLite3

public struct SQLiteError: Error {
    let code: Int
    let localizedDescription: String

    public init(code: CInt) {
        self.code = Int(code)
        self.localizedDescription = if let pointer = sqlite3_errstr(code) {
            String(cString: pointer)
        } else {
            "<no message>"
        }
    }

    @discardableResult
    static func check(_ error: CInt, permitting allowed: Set<CInt> = []) throws -> CInt {
        if !allowed.contains(error) {
            guard error == SQLITE_OK else {
                throw Self(code: error)
            }
        }

        return error
    }
}
