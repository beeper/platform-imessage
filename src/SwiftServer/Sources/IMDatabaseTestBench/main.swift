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
var states = try db.queryUnreadStates()

for try await _ in db.changes.subscribe() {
    let newStates = try db.queryUnreadStates()
    defer { states = newStates }

    var changedStates = IMDatabase.UnreadStates()
    for (chatId, newState) in newStates where states[chatId] != newState {
        changedStates[chatId] = newState
    }

    print(changedStates)
}
