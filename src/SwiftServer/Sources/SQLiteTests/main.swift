import Foundation
import SQLite
import Testing

@Test func basicQuery() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    try database.execute(sqlWithoutEscaping: "CREATE TABLE foo (bar TEXT)")
    try database.execute(sqlWithoutEscaping: "INSERT INTO foo VALUES (\"hi\")")

    let stmt = try database.prepare(sqlWithoutEscaping: "SELECT bar FROM foo")
    try stmt.stepUntilDone { row in
        #expect(row[0].as(String.self) == "hi")
    }
}
