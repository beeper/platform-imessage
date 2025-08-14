import ArgumentParser
import Foundation
import IMDatabase
import Logging
import SQLite

private func bootstrap(logLevel: Logger.Level = .trace) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = logLevel
        return handler
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}

@main
struct TestBench: AsyncParsableCommand {
    struct Options: ParsableArguments {
        @Option(name: [.long, .customShort("l")], help: "Specify the log level.")
        var logLevel: Logger.Level = .trace
    }

    static let configuration = CommandConfiguration(
        abstract: "Exercise functionality in IMDatabase.",
        subcommands: [Watch.self, Chats.self, FSEventsCommand.self],
    )

    mutating func run() async throws {}
}

extension TestBench {
    enum Filter: String, CaseIterable, ExpressibleByArgument {
        case biz

        func test(against chat: Chat) -> Bool {
            switch self {
            case .biz: chat.isBusiness
            }
        }
    }
}

// MARK: - Chats

extension TestBench {
    struct Chats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Queries the database for chats.",
            aliases: ["c"],
        )

        @OptionGroup var options: TestBench.Options

        @Option(name: .shortAndLong, help: "Only display chats satisfying filters.")
        var filter: [Filter] = []

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let db = try IMDatabase()
            let states = try Dictionary(uniqueKeysWithValues: db.queryUnreadStates().map { chatRef, state in
                (chatRef.rowID!, state)
            })

            for chat in try db.chats() where filter.allSatisfy({ $0.test(against: chat) }) {
                chat.dump()

                if let state = states[chat.id] {
                    if #available(macOS 12, *) {
                        let relativeDate = state.lastReadMessageTimestamp.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
                        print("- \(state) (\(relativeDate))")
                    }
                } else {
                    print("\u{1b}[31m- no unread state\u{1b}[0m")
                }

                print()
            }
        }
    }
}

private extension Chat {
    func dump() {
        var header = "\u{1b}[1m"

        if let displayName {
            header += displayName.isEmpty ? "(empty display name)" : "\"\(displayName)\""
        } else {
            header += "(no display name)"
        }

        header += " <\(guid)> [\(id)]\u{1b}[0m"
        print(header)

        if isBusiness {
            print("\u{1b}[35m- business chat\u{1b}[0m")
        }
    }
}

// MARK: - Watch

extension TestBench {
    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Watches the database for changes and prints changes.",
            aliases: ["w"],
        )

        @OptionGroup var options: TestBench.Options

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

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

                print("changed unread states:", changedStates)
            }
        }
    }
}

// MARK: - FSEvents

extension TestBench {
    struct FSEventsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fs-watch",
            abstract: "Tests file system watcher implementations.",
        )

        @OptionGroup var options: TestBench.Options

        @Argument(help: "The paths to monitor. Each path is monitored by both FSEvents and DispatchSourceFileSystemObject.") var targetPaths: [String]
        @Flag(name: [.customLong("fs-events-files"), .customShort("f")], help: "Whether to tell FSEvents to observe file activity for the specified paths.") var fsEventsFiles = false

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let fsEventsQueue = DispatchQueue(label: "IMDatabaseTestBench FSEvents")
            let dateFormatter = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullTime, .withFractionalSeconds]
                return formatter
            }()

            func now() -> String {
                "\u{1b}[90;3m[" + dateFormatter.string(from: Date()) + "]\u{1b}[0m"
            }

            func watchWithFSEvents(path: String) throws {
                let fsEventsWatcher = try FSEventsWatcher(watchingPath: path, includingFiles: fsEventsFiles)

                Task {
                    for try await event in fsEventsWatcher.events.subscribe() {
                        print("\(now()) \u{1b}[1;32m<FSEvents>      \u{1b}[0m [\(event.id)] \(event.path.shortenedPath) \u{1b}[1m\(event.flags)\u{1b}[0m")
                    }
                }

                fsEventsWatcher.setDispatchQueue(fsEventsQueue)
                try fsEventsWatcher.start()
            }

            func watchWithDispatchSource(path: String) throws {
                let watcher = FileWatcher(watching: URL(fileURLWithPath: path))

                Task {
                    for try await event in watcher.events.subscribe() {
                        print("\(now()) \u{1b}[1;34m<DispatchSource>\u{1b}[0m (\(path.shortenedPath)) \u{1b}[1m<\(event.imdb_description)>\u{1b}[0m")
                    }
                }

                try watcher.beginListening()
            }

            for path in targetPaths {
                try watchWithFSEvents(path: path)
                try watchWithDispatchSource(path: path)
            }

            // `dispatchMain` crashes
            await Task.never()
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func never() async {
        let empty = AsyncStream<Never> { _ in }
        for await _ in empty {}
    }
}

private extension String {
    var shortenedPath: String {
        replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func padEnd(to length: Int) -> String {
        self + String(repeating: " ", count: max(0, length - count))
    }
}

private extension DispatchSource.FileSystemEvent {
    var imdb_description: String {
        switch self {
        case .all: "all"
        case .attrib: "attrib"
        case .delete: "delete"
        case .extend: "extend"
        case .funlock: "funlock"
        case .link: "link"
        case .rename: "rename"
        case .revoke: "revoke"
        case .write: "write"
        default: "unknown"
        }
    }
}
