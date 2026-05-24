import AsyncAlgorithms
import Foundation
import Logging
import SQLite
import IMessageCore

private func chatDatabaseFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db")
}

private func chatDatabaseWalFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db-wal")
}

private let log = Logger(label: "imdb")

private let messageIndexes = [
    ("message_idx_date_read", "date_read"),
    ("message_idx_date_edited", "date_edited"),
]

public final class IMDatabase {
    // `~/Library/Messages/`
    let messagesDataDirectory: URL
    // coalesce multiple filesystem changes if they happen in a short period
    public var debounceInterval: DispatchTimeInterval = .milliseconds(25)

    // let clients of this class subscribe to changes in in the `chat.db` file
    // (includes `chat.db-wal`, `chat.db-shm`). broadcasts to this `Topic` are
    // debounced
    public let changes = Topic<Void>()

    private var fsEventsQueue = DispatchQueue(label: "imdb.fs-events")
    // file watchers for `chat.db` and `chat.db-wal`; these need to be
    // dynamically populated because the WAL can be deleted and (re)created at
    // any time
    private var fileWatchers = [String: FileWatcher]()

    private let listenerLock = Protected(())
    private var directoryWatcher: FSEventsWatcher?
    private var debouncer: Task<Void, Never>?

    public var noisy = false

    var database: Database

    private var statementCache = [String: Statement]()
    var tableColumnCache = [String: [String]]()

    public init(messagesDataBaseURL: URL? = nil, createIndexes: Bool = false) throws {
        let messagesDataDirectory = messagesDataBaseURL ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Messages/")
        self.messagesDataDirectory = messagesDataDirectory
        #if DEBUG
        log.debug("creating database with messages data directory: \(messagesDataDirectory)")
        defer { log.debug("database created") }
        #endif

        if createIndexes {
            try Self.createIndexesIfNecessary(in: messagesDataDirectory)
        }

        self.database = try Database(connecting: chatDatabaseFile(in: messagesDataDirectory).path, flags: .readOnly)
    }

    func cachedStatement(forEscapedSQL sql: String) throws -> Statement {
        if let cached = statementCache[sql] {
            return cached
        }

        let statement = try Statement.prepare(escapedSQL: sql, for: database, flags: .persistent)
        statementCache[sql] = statement
        return statement
    }

    deinit {
        log.debug("being deallocated, stopping watchers and listeners if necessary")
        listenerLock.withLock { _ in
            stopListeningForChangesLocked()
        }
    }
}

private extension IMDatabase {
    static func createIndexesIfNecessary(in messagesDataDirectory: URL) throws {
        let database = try Database(connecting: chatDatabaseFile(in: messagesDataDirectory).path, flags: .readWrite)
        let messageColumns = try database.tableColumns("message")

        for (indexName, columnName) in messageIndexes where messageColumns.contains(columnName) {
            try database.execute(sqlWithoutEscaping: "CREATE INDEX IF NOT EXISTS \(indexName) ON message (\(columnName))")
        }
    }
}

// MARK: - Listening for Changes

public extension IMDatabase {
    func beginListeningForChanges() throws {
        try listenerLock.withLock { _ in
            guard directoryWatcher == nil else { return }
            try startListeningForChangesLocked()
        }
    }

    func stopListeningForChanges() {
        listenerLock.withLock { _ in
            stopListeningForChangesLocked()
        }
    }

    private func stopListeningForChangesLocked() {
        if let directoryWatcher {
            directoryWatcher.stop()
            directoryWatcher.invalidate()
            self.directoryWatcher = nil
        }

        debouncer?.cancel()
        debouncer = nil

        for watcher in fileWatchers.values {
            watcher.stopListeningIfNecessary()
        }
        fileWatchers.removeAll()
    }

    private func startListeningForChangesLocked() throws {
        log.info("setting up filesystem watchers")

        stopListeningForChangesLocked()

        let unthrottledChanges = Topic<Void>()

        do {
            try setUpListeners(unthrottledChanges: unthrottledChanges)
        } catch {
            stopListeningForChangesLocked()
            throw error
        }
    }

    private func setUpListeners(unthrottledChanges: Topic<Void>) throws {
        // listen to ~/Library/Messages itself in order to respond to the WAL
        // file being (re)created/deleted
        let directoryWatcher = try FSEventsWatcher(watchingPath: messagesDataDirectory.path, latency: 1.0) { [weak self] _, event in
            guard let self else { return }

            // we don't pass `includingFiles: true` to the FSEvents to reduce
            // traffic from fseventsd (and any potential overall overhead).
            // therefore, we'll indiscriminately ensure the WAL file watchers
            // in response to any events directly under `~/Library/Messages`
            //
            // as a nice side effect, this avoids logging paths with PII such as
            // subdirs under `Attachments`/`NickNameCache`, etc.
            //
            // it's ok to always log even when !noisy because we don't hit this
            // path for every WAL change; that's what the file watchers are for.
            // we'll only get here on files being (re)created/deleted
            guard event.path.hasSuffix("Messages/") else { return }
            let anonymizedPath = event.path.replacingOccurrences(of: "\(NSHomeDirectory())", with: "~")
            log.debug("received FSEvent [\(event.id)] \(anonymizedPath) \(event.flags)")

            do {
                try listenerLock.withLock { _ in
                    try self.ensureDatabaseFileWatchers(broadcastingTo: unthrottledChanges)
                }
            } catch {
                log.error("failed to ensure database file watchers in response to WAL file event: \(error)")
            }
        }
        directoryWatcher.setDispatchQueue(fsEventsQueue)
        try directoryWatcher.start()
        self.directoryWatcher = directoryWatcher

        try ensureDatabaseFileWatchers(broadcastingTo: unthrottledChanges)

        debouncer = Task { [weak self] in
            // this can't actually throw, but we can't use `AsyncSequence`'s
            // `Failure` type argument due to deployment
            do {
                try await self?.broadcastDebouncedChanges(from: unthrottledChanges)
            } catch {
                log.error("debouncer died: \(error)")
            }
        }
    }

    private func ensureDatabaseFileWatchers(broadcastingTo topic: Topic<Void>) throws {
        let desiredWatchFiles = [
            DatabaseWatchFile(url: chatDatabaseFile(in: messagesDataDirectory), required: true),
            DatabaseWatchFile(url: chatDatabaseWalFile(in: messagesDataDirectory), required: false),
        ]
        let desiredWatchPaths = Set(desiredWatchFiles.map(\.url.path))

        let staleWatchPaths = fileWatchers.keys.filter { !desiredWatchPaths.contains($0) }
        for path in staleWatchPaths {
            log.debug("purging stale FileWatcher for \(URL(fileURLWithPath: path).lastPathComponent)")
            fileWatchers.removeValue(forKey: path)?.stopListeningIfNecessary()
        }

        let unlinkedWatchPaths = fileWatchers.compactMap { path, watcher -> String? in
            do {
                return try watcher.hasHardLinks() == true ? nil : path
            } catch {
                log.error("couldn't check if \(watcher) has hard links, recreating it: \(error)")
                return path
            }
        }
        for path in unlinkedWatchPaths {
            log.debug("purging unlinked FileWatcher for \(URL(fileURLWithPath: path).lastPathComponent)")
            fileWatchers.removeValue(forKey: path)?.stopListeningIfNecessary()
        }

        func makeWatcher(for file: URL) throws -> FileWatcher {
            log.debug("setting up FileWatcher for \(file.lastPathComponent)")

            let watcher = FileWatcher(watching: file) { [weak self] _, event in
                guard let self else { return }

                if noisy {
                    log.debug("(noisy) DispatchSource: \(event)")
                }
                topic.broadcast(())
            }

            try watcher.beginListening()
            return watcher
        }

        var newWatchers = [String: FileWatcher]()
        for file in desiredWatchFiles where fileWatchers[file.url.path] == nil {
            do {
                newWatchers[file.url.path] = try makeWatcher(for: file.url)
            } catch {
                if file.required {
                    log.debug("failed to set up required database file watcher, cleaning up \(newWatchers.count) new watcher(s)")
                    for watcher in newWatchers.values {
                        watcher.stopListeningIfNecessary()
                    }
                    throw error
                }
                log.debug("could not watch optional \(file.url.lastPathComponent); will retry on directory events: \(error)")
            }
        }

        for (path, watcher) in newWatchers {
            fileWatchers[path] = watcher
        }

        log.debug("watcher count after ensuring: \(fileWatchers.count)")
    }

    private struct DatabaseWatchFile {
        var url: URL
        var required: Bool
    }

    private func broadcastDebouncedChanges(from topic: Topic<Void>) async throws {
        var broadcaster: Task<Void, any Error>?

        for try await _ in topic.subscribe() {
            guard !Task.isCancelled else {
                log.debug("debouncer was cancelled, bailing")
                return
            }

            broadcaster?.cancel()
            broadcaster = Task { [weak self] in
                guard let self else { return }

                try await Task.sleep(nanoseconds: debounceInterval.nanoseconds)
                try Task.checkCancellation()

                if noisy {
                    log.debug("(noisy) IMDatabase is going to broadcast a change, post-debounce")
                }
                changes.broadcast(())
            }
        }
    }
}
