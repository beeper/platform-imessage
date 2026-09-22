import ArgumentParser
import Foundation
import IMDatabase
import Logging
import SQLite
import IMessageCore

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
        subcommands: [Watch.self, Messages.self, Chats.self, UnreadBenchmark.self, FSEventsCommand.self, ClosestSelectable.self],
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

// MARK: - Unread Benchmark

extension TestBench {
    struct UnreadBenchmark: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bench-unreads",
            abstract: "Benchmarks unread-state database queries."
        )

        @OptionGroup var options: TestBench.Options

        @Option(name: .shortAndLong, help: "The number of timed runs for each query.")
        var iterations: Int = 20

        @Option(name: .long, help: "The number of chat GUIDs to use for the per-chat read-state query.")
        var affectedChatCount: Int = 1

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let db = try IMDatabase()
            let initialStates = try db.chatStates()
            let chatGUIDs = Array(initialStates.keys).sorted()
            let affectedChatGUIDs = Array(chatGUIDs.prefix(max(affectedChatCount, 0)))

            print("tracked chats with messages: \(chatGUIDs.count)")
            print("initial unread chats: \(initialStates.values.filter(\.isUnread).count)")
            print("per-chat read-state sample size: \(affectedChatGUIDs.count)")

            try benchmark("chatStates() full pass", iterations: iterations) {
                _ = try db.chatStates()
            }

            if !affectedChatGUIDs.isEmpty {
                let result = try benchmark("isThreadRead(chatGUID:) x\(affectedChatGUIDs.count)", iterations: iterations) {
                    for chatGUID in affectedChatGUIDs {
                        _ = try db.isThreadRead(chatGUID: chatGUID)
                    }
                }
                print("isThreadRead(chatGUID:) per chat: avg \((result.average / Double(affectedChatGUIDs.count)).formattedMs)")
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

        @Option(name: .shortAndLong, help: "Only fetches before or after the specified date.", transform: MessageQueryFilter.parse)
        var filter: MessageQueryFilter?

        @Option(name: .shortAndLong, help: "Order the query results.")
        var order: DateOrdering = .newestFirst

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let db = try IMDatabase()

            guard let chat = try db.chat(withGUID: chatGUID) else {
                print("No such chat.")
                throw ExitCode.success
            }

            let messages = try db.messages(in: chat.guid, filter: filter, order: order, limit: limit)

            for message in messages {
                message.dump()
            }
        }
    }
}

private extension Message {
    func dump() {
        let tags: String = {
            let tags = [isFromMe ? "(from me)" : nil, isSent ? "(is sent)" : nil].compactMap(\.self)
            guard !tags.isEmpty else {
                return ""
            }
            return " \u{1b}[1;34m\(tags.joined(separator: ", "))\u{1b}[0m"
        }()

        print("\u{1b}[1m\(guid)\u{1b}[0m #\(id), \(date.formattedForDebugging)\(tags)")
        if let text = text?.unwrappingSensitiveData() {
            print("  text: \(text)")
        }
        if let attributedBody = attributedBody?.unwrappingSensitiveData() {
            print("  attributed body: \(attributedBody)")
        }

        if let attachments {
            for (index, attachment) in attachments.enumerated() {
                print("  attachment \(index + 1)/\(attachments.count): \(attachment)")
            }
        }

        if let summaryInfo {
            print("  summary info:", summaryInfo)
        }
        print()
    }
}

extension TestBench {
    struct ClosestSelectable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Finds the closest selectable message relative to another message.",
            aliases: ["closest"],
            )

        @OptionGroup var options: TestBench.Options

        @Argument(help: "The GUID of the target message.", transform: GUID.init)
        var messageGUID: GUID<Message>

        @Argument(help: "The part of the target message to use as a starting point for locating the closest selectable part.", transform: { arg in
            guard let index = Int(arg) else {
                throw ValidationError("message part isn't an integer: \(arg)")
            }
            return Message.Part.Index(rawValue: index)
        })
        var partIndex: Message.Part.Index

        mutating func run() async throws {
            bootstrap(logLevel: options.logLevel)

            let db = try IMDatabase()

            guard let (message, chatGUID) = try db.message(with: messageGUID) else {
                Self.exit(withError: ErrorMessage("Message with GUID \"\(messageGUID)\" not found."))
            }

            print()
            print("chat GUID: \(chatGUID)")
            let parts = message.parts
            guard let part = parts.first(where: { $0.index == partIndex }) else {
                Self.exit(withError: ErrorMessage("Message \"\(messageGUID)\" doesn't have a part with index \(partIndex) (part indices: \(parts.map(\.index))."))
            }
            print("target part: \(part)")
            print()
            print("(original message)")
            message.dump()
            print(String(repeating: "=", count: 100))

            guard let closest = try db.findClosestSelectablePart(from: part, parentMessage: message, in: chatGUID) else {
                Self.exit(withError: ErrorMessage("Couldn't find a closest selectable message."))
            }

            print()
            print()
            print("(closest selectable)")
            print("\u{1b}[1;32mtarget relative offset (in parts): \(closest.offsetFromTarget)\u{1b}[0m")
            print("\u{1b}[1;32mselectable part:", closest.closestSelectable, "\u{1b}[0m")
            print()
        }
    }
}

private struct BenchmarkResult {
    var average: Double
    var median: Double
    var p95: Double
}

@discardableResult
private func benchmark(_ label: String, iterations: Int, block: () throws -> Void) throws -> BenchmarkResult {
    let iterations = max(iterations, 1)
    var measurements = [Double]()
    measurements.reserveCapacity(iterations)

    try block()

    for _ in 0 ..< iterations {
        let start = Date()
        try block()
        measurements.append(start.elapsedMilliseconds)
    }

    let sorted = measurements.sorted()
    let average = measurements.reduce(0, +) / Double(measurements.count)
    let median = percentile(0.5, in: sorted)
    let p95 = percentile(0.95, in: sorted)

    print("\(label): avg \(average.formattedMs), median \(median.formattedMs), p95 \(p95.formattedMs)")
    return BenchmarkResult(average: average, median: median, p95: p95)
}

private func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
    guard let first = sortedValues.first else { return 0 }
    guard sortedValues.count > 1 else { return first }

    let boundedPercentile = min(max(percentile, 0), 1)
    let index = Int((Double(sortedValues.count - 1) * boundedPercentile).rounded())
    return sortedValues[index]
}

private extension Double {
    var formattedMs: String {
        String(format: "%.2fms", self)
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
            let states = try db.chatStates()

            for chat in try db.chats() where filter.allSatisfy({ $0.test(against: chat) }) {
                chat.dump()

                if let state = states[chat.guid.description] {
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
            var states = try db.chatStates()

            for try await _ in db.changes.subscribe() {
                let newStates = try db.chatStates()
                defer { states = newStates }

                var changedChatStates: [String: ChatState] = [:]
                for (chatGUID, newState) in newStates where states[chatGUID] != newState {
                    changedChatStates[chatGUID] = newState
                }

                print("changed unread states:", changedChatStates)
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
