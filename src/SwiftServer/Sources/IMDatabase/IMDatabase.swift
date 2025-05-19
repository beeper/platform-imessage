import AsyncAlgorithms
import Foundation
import SQLite
import SwiftServerFoundation

private func chatDatabaseFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db")
}

private func chatDatabaseWalFile(in messagesDataURL: URL) -> URL {
    messagesDataURL.appendingPathComponent("chat.db-wal")
}

public final class IMDatabase {
    let messagesDataDirectory: URL
    public var debounceIntervalMs: Int = 25
    public let changes = Topic<Void>()

    private var dbWatcher: FileWatcher?
    private var dbWalWatcher: FileWatcher?
    private var listener: Task<Void, Never>?

    private var database: ReadOnlyDatabase

    public init(messagesDataBaseURL: URL? = nil) throws {
        messagesDataDirectory = messagesDataBaseURL ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Messages/")
        database = try ReadOnlyDatabase(connecting: chatDatabaseFile(in: messagesDataDirectory).path)
    }
}

public extension IMDatabase {
    func beginListeningForChanges() throws {
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
            try? await self?.listenForChanges(consuming: changes)
        }
    }

    private func listenForChanges(consuming sequence: some AsyncSequence) async throws {
        var broadcastingTask: Task<Void, any Error>?

        for try await _ in sequence {
            broadcastingTask?.cancel()
            broadcastingTask = Task { [weak self] in
                guard let self else { return }

                let debouncingPeriod = UInt64(debounceIntervalMs * 1_000_000)
                try await Task.sleep(nanoseconds: debouncingPeriod)
                try Task.checkCancellation()

                changes.broadcast(())
            }
        }
    }
}
