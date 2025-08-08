import Foundation
import SQLite
import Testing

@Test func basicQuery() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    try database.execute(sqlWithoutEscaping: "CREATE TABLE foo (bar TEXT)")
    try database.execute(sqlWithoutEscaping: "INSERT INTO foo VALUES (\"hi\"), (NULL)")

    let stmt = try database.prepare(sqlWithoutEscaping: "SELECT bar FROM foo")
    let strings = try stmt.mapRowsUntilDone { row in
        try row[0].optional(String.self)
    }
    #expect(strings == ["hi", nil])
}

@Test func optionals() throws {
    let database = try Database(connecting: ":memory:", flags: .readWrite)
    try database.execute(sqlWithoutEscaping: "CREATE TABLE vals (val)")
    try database.execute(sqlWithoutEscaping: "INSERT INTO vals VALUES (NULL)")

    let stmt = try database.prepare(sqlWithoutEscaping: "SELECT val FROM vals")
    try stmt.stepUntilDone { row in
        #expect(throws: Column.Error.expectedSpecificType(columnIndex: 0, desired: .text, actual: .null, sourceLocation: .anywhere)) {
            try row[0].expect(String.self)
        }
        #expect(throws: Column.Error.expectedSomeNonNull(columnIndex: 0, preference: .integer, sourceLocation: .anywhere)) {
            try row[0].expectConverting(Int.self)
        }

        try #expect(row[0].optional(String.self) == nil)
        try #expect(row[0].optionalConverting(String.self) == nil)
    }
}

