import ArgumentParser
import Foundation
import IMDatabase
import Logging
import SQLite
import SwiftServerFoundation

private func bootstrap(logLevel: Logger.Level = .trace) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = logLevel
        return handler
    }
}

@main
struct TestBench: AsyncParsableCommand {
    struct Options: ParsableArguments {
        @Option(name: .long, help: "Specify the log level.")
        var logLevel: Logger.Level = .trace
    }

    static let configuration = CommandConfiguration(
        abstract: "Exercise functionality in IMDatabase.",
        subcommands: [Watch.self, Messages.self, Chats.self, FSEventsCommand.self, TestIdleAware.self],
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

// MARK: - Messages

extension TestBench {
    struct Messages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Queries the database for messages.",
            aliases: ["m"],
        )

        @OptionGroup var options: TestBench.Options

        @Argument(help: "The GUID of the chat to query messages from.")
        var chatGUID: String

        @Option(name: .shortAndLong, help: "The maximum number of messages to fetch.")
        var limit: Int = 50

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let db = try IMDatabase()

            guard let chat = try db.chat(withGUID: chatGUID) else {
                print("No such chat.")
                throw ExitCode.success
            }

            let messages = try db.messages(in: chat.guid, limit: limit)

            for message in messages {
                let tags: String = {
                    let tags = [message.isFromMe ? "(from me)" : nil, message.isSent ? "(is sent)" : nil].compactMap(\.self)
                    guard !tags.isEmpty else {
                        return ""
                    }
                    return " \u{1b}[1;34m\(tags.joined(separator: ", "))\u{1b}[0m"
                }()

                print("\u{1b}[1m\(message.guid)\u{1b}[0m #\(message.id), \(message.date.formatted)\(tags)")
                if let text = message.text?.unwrappingSensitiveData() {
                    print("  text: \(text)")
                }
                if let attributedBody = message.attributedBody?.unwrappingSensitiveData() {
                    print("  attributed body: \(attributedBody)")
                }
                print()
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
        print({
            var header = "\u{1b}[1m\(guid)\u{1b}[0m "
            if let displayName {
                header += "\"\(displayName)\""
            } else {
                header += "(no display name)"
            }

            header += " #\(id)\u{1b}[0m"
            return header
        }())

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
        @Option(name: [.customLong("fse-latency"), .customShort("l")], help: "The latency to use when leveraging FSEvents to observe file activity..") var latency: Double = 1.0 / 60.0
        @Flag(name: [.customLong("fse-files"), .customShort("f")], help: "Whether to tell FSEvents to observe file activity for the specified paths.") var fsEventsFiles = false

        enum Event {
            case fse(source: FSEventsWatcher, FSEventsWatcher.Event)
            case dispatch(source: FileWatcher, path: String, DispatchSource.FileSystemEvent)
        }

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

            let topic = Topic<Event>()
            var watchers = [Any]()

            func watchWithFSEvents(path: String) throws {
                let fsEventsWatcher = try FSEventsWatcher(watchingPath: path, includingFiles: fsEventsFiles, latency: latency) { watcher, event in
                    topic.broadcast(.fse(source: watcher, event))
                }
                fsEventsWatcher.setDispatchQueue(fsEventsQueue)
                try fsEventsWatcher.start()
                watchers.append(fsEventsWatcher)
            }

            func watchWithDispatchSource(path: String) throws {
                let watcher = FileWatcher(watching: URL(fileURLWithPath: path), onEvent: { watcher, event in
                    topic.broadcast(.dispatch(source: watcher, path: path, event))
                })
                try watcher.beginListening()
                watchers.append(watcher)
            }

            for path in targetPaths {
                try watchWithFSEvents(path: path)
                try watchWithDispatchSource(path: path)
            }

            print("total watcher count: \(watchers.count)")

            Task {
                for try await event in topic.subscribe() {
                    switch event {
                    case let .fse(_, event):
                        print("\(now()) \u{1b}[1;32m<FSEvents>      \u{1b}[0m [\(event.id)] \(event.path.shortenedPath) \u{1b}[1m\(event.flags)\u{1b}[0m")
                    case let .dispatch(source, path, event):
                        let linksLabel = switch try source.hasHardLinks() {
                        case .some(true): "\u{1b}[1;32m(has links)\u{1b}[0m"
                        case .some(false): "\u{1b}[1;31m(no links)\u{1b}[0m"
                        case nil: "\u{1b}[1;33m(unknown)\u{1b}[0m"
                        }
                        print("\(now()) \u{1b}[1;34m<DispatchSource>\u{1b}[0m (\(path.shortenedPath)) \u{1b}[1m<\(event.imdb_description)>\u{1b}[0m \(linksLabel)")
                    }
                }
            }

            // calling `dispatchMain` crashes, so do this instead
            await Task.never()
        }
    }
}

// MARK: - Idle Aware

extension TestBench {
    struct TestIdleAware: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test-idle-aware",
            abstract: "Tests the idle aware queue."
        )
        @OptionGroup var options: TestBench.Options

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let queue = PassivelyAwareDispatchQueue(label: "test", idleDelay: 0.1)

            queue.setIdleCallback { info in
                print("*** IDLE! *** [0.1s] <\(info)>")
                Thread.sleep(forTimeInterval: 0.1)
            }

            queue.async {
                print("1. [1s]")
                Thread.sleep(forTimeInterval: 1)
            }
            queue.async {
                print("2. [0.5s]")
                Thread.sleep(forTimeInterval: 0.5)
            }
            queue.async {
                print("3. [0.25s]")
                Thread.sleep(forTimeInterval: 0.25)
            }

            Task {
                while true {
                    let ms = Int.random(in: 500...4_000)
                    try! await Task.sleep(nanoseconds: UInt64(1_000_000 * ms))

                    queue.async {
                        let cost = Double.random(in: 0.5...1)
                        print("r. [\(cost)s]")
                        Thread.sleep(forTimeInterval: cost)
                    }
                }
            }

            await Task.never()
        }
    }
}
