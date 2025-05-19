import Foundation
import IMDatabase
import Logging

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .trace
    return handler
}

let db = try IMDatabase()
try db.beginListeningForChanges()

for await _ in db.changes.subscribe() {
    print("** change detected **")
}
