import AsyncAlgorithms
import Foundation
import SQLite
import SwiftServerFoundation
import Logging

private func chatDatabaseFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db")
}

private func chatDatabaseWalFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db-wal")
}

private let log = Logger(label: "imdb")

public final class IMDatabase {
    // `~/Library/Chat`
    let messagesDataDirectory: URL
    // coalesce multiple filesystem changes if they happen in a short period
    public var debounceIntervalMs: Int = 25
    // let consumers of this class subscribe to changes in either `chat.db`
    // or `chat.db-wal`
    public let changes = Topic<Void>()

    // watch filesystem for changes in `chat.db` and `chat.db-wal` in order to
    // respond to events
    private var dbWatcher: FileWatcher?
    private var dbWalWatcher: FileWatcher?
    private var listener: Task<Void, Never>?

    var database: Database

    // prepared statement caching
    var unreadStatesStatement: Statement?
    var messageUpdatesStatement: Statement?
    var chatWithGUIDStatement: Statement?
    var handlesInChatWithGUIDStatement: Statement?

    public init(messagesDataBaseURL: URL? = nil) throws {
        messagesDataDirectory = messagesDataBaseURL ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Messages/")
#if DEBUG
        log.debug("creating database with messages data directory: \(messagesDataDirectory)")
        defer { log.debug("database created") }
#endif
        database = try Database(connecting: chatDatabaseFile(in: messagesDataDirectory).path, flags: .readOnly)
    }

    func cachedStatement(_ statement: inout Statement?, creatingWithoutEscapingSQL sql: String) throws -> Statement {
        if let statement {
            return statement
        }

        let prepared = try database.prepare(sqlWithoutEscaping: sql, flags: .persistent)
        statement = prepared
        return prepared
    }

    deinit {
        log.debug("being deallocated, stopping watchers and listeners if necessary")
        dbWatcher?.stopListeningIfNecessary()
        dbWalWatcher?.stopListeningIfNecessary()
        listener?.cancel()
    }
}

// MARK: - Listening for Changes

// rely on watching filesystem for `chat.db`/`chat.db-wal` changes in order to
// respond by querying the database.

public extension IMDatabase {
    func beginListeningForChanges() throws {
        log.info("beginning to listen for changes")

        let dbWatcher = FileWatcher(watching: chatDatabaseFile(in: messagesDataDirectory))
        try dbWatcher.beginListening()
        let dbWalWatcher = FileWatcher(watching: chatDatabaseWalFile(in: messagesDataDirectory))
        try dbWalWatcher.beginListening()

        self.dbWatcher = dbWatcher
        self.dbWalWatcher = dbWalWatcher

        let changes = merge(dbWalWatcher.events.subscribe(), dbWatcher.events.subscribe())
        listener = Task { [weak self] in
            // this can't actually throw, but we can't use `AsyncSequence`'s
            // `Failure` type argument due to deployment
            do {
                try await self?.listenAndBroadcastChanges(consuming: changes)
            } catch {
                log.error("database file watcher died: \(error)")
            }
        }
    }

    private func listenAndBroadcastChanges(consuming sequence: some AsyncSequence) async throws {
        var broadcastingTask: Task<Void, any Error>?

        for try await _ in sequence {
            guard !Task.isCancelled else {
                log.debug("was cancelled while listening for database file changes, bailing")
                return
            }
            broadcastingTask?.cancel()
            broadcastingTask = Task { [weak self] in
                guard let self else { return }

                let debouncingPeriod = UInt64(debounceIntervalMs * 1_000_000)
                try await Task.sleep(nanoseconds: debouncingPeriod)
                try Task.checkCancellation()

#if DEBUG
                log.debug("detected database change")
#endif
                changes.broadcast(())
            }
        }
    }
}
