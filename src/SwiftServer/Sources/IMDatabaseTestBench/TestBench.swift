import Foundation
import IMDatabase
import SQLite
import Logging
import ArgumentParser

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

    mutating func run() async throws {
    }
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
            let states = Dictionary(uniqueKeysWithValues: try db.queryUnreadStates().map { (chatRef, state) in
                (chatRef.rowID!, state)
            })

            for (chatIndex, chat) in try db.chats().enumerated() where filter.allSatisfy({ $0.test(against: chat)}) {
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
            commandName: "fs-events",
            abstract: "Tests the FSEvents wrapper implementation.",
        )

        @OptionGroup var options: TestBench.Options

        @Argument(help: "The path to the directory to monitor.") var targetPath: String
        @Flag(help: "Whether to observe file activity within the monitored directory.") var files = false

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)
            let queue = DispatchQueue(label: "IMDatabaseTestBench FSEvents")

            let watcher = try FSEvents(watchingPath: targetPath, includingFiles: files)

            Task {
                for try await event in watcher.events.subscribe() {
                    print("[\(event.id)] \(event.path) \(event.flags)")
                }
            }

            watcher.setDispatchQueue(queue)
            try watcher.start()
            // `dispatchMain` crashes
            await Task.never()
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func never() async -> Void {
        let empty = AsyncStream<Never> { _ in }
        for await _ in empty {}
    }
}
