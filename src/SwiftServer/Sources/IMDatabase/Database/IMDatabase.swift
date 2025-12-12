import AsyncAlgorithms
import Foundation
import Logging
import SQLite
import SwiftServerFoundation


private let log = Logger(label: "imdb")

public final class IMDatabase {
    // `~/Library/Messages/`
    let messagesDataDirectory: URL
    
    var chatDatabaseFileURL: URL
    var chatDatabaseWALFileURL: URL

    // coalesce multiple filesystem changes if they happen in a short period
    public var debounceIntervalMs: Int = 25

    // let clients of this class subscribe to changes in in the `chat.db` file
    // (includes `chat.db-wal`, `chat.db-shm`). broadcasts to this `Topic` are
    // debounced
    public let changes = Topic<Void>()

    private var fsEventsQueue = DispatchQueue(label: "imdb.fs-events")
    private var messagesDirectoryWatcher: FSEventsWatcher?
    // file watchers for `chat.db` and `chat.db-wal`; these need to be
    // dynamically populated because the WAL can be deleted and (re)created at
    // any time
    private var fileWatchers = [FileWatcher]()

    private var debouncer: Task<Void, Never>?

    public var noisy = false

    var database: Database

    private var statementCache = [String: Statement]()

    public init(messagesDataBaseURL: URL? = nil) throws {
        self.messagesDataDirectory = messagesDataBaseURL ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Messages/")
        self.chatDatabaseFileURL = messagesDataDirectory.appendingPathComponent("chat.db")
        self.chatDatabaseWALFileURL = messagesDataDirectory.appendingPathComponent("chat.db-wal")


#if DEBUG
        log.debug("creating database with messages data directory: \(messagesDataDirectory)")
        defer { log.debug("database created") }
#endif
        self.database = try Database(connecting: chatDatabaseFileURL.path, flags: .readOnly)
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

        fileWatchers.forEach { $0.stopListeningIfNecessary() }
        
        debouncer?.cancel()
        debouncer = nil
    }
}

// MARK: - Listening for Changes

public extension IMDatabase {
    func beginListeningForChanges() throws {
        log.info("setting up filesystem watchers")

        let unthrottledChanges = Topic<Void>()

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
                try ensureDatabaseFileWatchers(broadcastingTo: unthrottledChanges)
            } catch {
                log.error("failed to ensure database file watchers in response to WAL file event: \(error)")
            }
        }
        directoryWatcher.setDispatchQueue(fsEventsQueue)
        try directoryWatcher.start()

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
        if !fileWatchers.isEmpty {
            let allWatchersHaveLinks = fileWatchers.allSatisfy { watcher in
                do {
                    return try watcher.hasHardLinks() == true
                } catch {
                    log.error("couldn't check if \(watcher) has hard links, assuming it does: \(error)")
                    return false
                }
            }

            guard !allWatchersHaveLinks else {
                log.debug("all file watchers have hard links, leaving them alone")
                return
            }

            log.debug("at least one file watcher lacks hard links, purging all of em (\(fileWatchers.count))")
            // TODO: watchers stop listening in deinit, so maybe this is
            // unnecessary assuming we have no refcycles
            for watcher in fileWatchers {
                watcher.stopListeningIfNecessary()
            }
            fileWatchers.removeAll()
        }

        func watchFile(at path: URL) throws {
            log.debug("setting up FileWatcher for \(path.lastPathComponent)")

            let watcher = FileWatcher(watching: path) { [weak self] _, event in
                guard let self else { return }

                if noisy {
                    log.debug("(noisy) DispatchSource: \(event)")
                }
                topic.broadcast(())
            }

            try watcher.beginListening()
            fileWatchers.append(watcher)
        }

        // watch `.db`/`.db-wal` files for changes
        try watchFile(at: chatDatabaseFileURL)
        try watchFile(at: chatDatabaseWALFileURL)

        log.debug("watcher count after ensuring: \(fileWatchers.count)")
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

                let debouncingPeriod = UInt64(debounceIntervalMs * 1_000_000)
                try await Task.sleep(nanoseconds: debouncingPeriod)
                try Task.checkCancellation()

                if noisy {
                    log.debug("(noisy) IMDatabase is going to broadcast a change, post-debounce")
                }
                changes.broadcast(())
            }
        }
    }
}
