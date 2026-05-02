import SQLite3

public enum SQLiteLibrary {
    public static var isThreadsafe: Bool {
        sqlite3_threadsafe() != 0
    }
}
