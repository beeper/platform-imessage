import ArgumentParser
import Darwin
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
        subcommands: [Watch.self, Messages.self, Chats.self, PollBenchmark.self, FSEventsCommand.self, TestIdleAware.self, ClosestSelectable.self],
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

        @Option(name: .shortAndLong, help: "Only fetches before or after the specified date.", transform: MessageQueryFilter.parse)
        var filter: MessageQueryFilter? = nil

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

        if let attachments = attachments {
            for (index, attachment) in attachments.enumerated() {
                print("  attachment \(index + 1)/\(attachments.count): \(attachment)")
            }
        }

        if let summaryInfo = summaryInfo {
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
            let states = try Dictionary(uniqueKeysWithValues: db.chatStates().map { chatRef, state in
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
            var states = try db.chatStates()

            for try await _ in db.changes.subscribe() {
                let newStates = try db.chatStates()
                defer { states = newStates }

                var changedChatStates: [ChatRef: ChatState] = [:]
                for (chatID, newState) in newStates where states[chatID] != newState {
                    changedChatStates[chatID] = newState
                }

                print("changed unread states:", changedChatStates)
            }
        }
    }
}

// MARK: - Poll Benchmark

extension TestBench {
    struct PollBenchmark: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "poll-benchmark",
            abstract: "Benchmarks the hot IMDatabase queries used by SwiftServer polling.",
            aliases: ["bench-poll"],
        )

        @Option(name: .long, help: "Specify the log level.")
        var logLevel: Logger.Level = .critical

        @Option(name: .long, help: "Use this Messages data directory instead of ~/Library/Messages.")
        var messagesDir: String?

        @Option(name: .shortAndLong, help: "Run for this many seconds. Ignored after --iterations is reached.")
        var duration: Double = 30

        @Option(name: .shortAndLong, help: "Stop after this many total poll cycles across all workers.")
        var iterations: Int?

        @Option(name: .shortAndLong, help: "Number of concurrent independent IMDatabase connections.")
        var concurrency: Int = 1

        @Option(name: .long, help: "Sleep this many milliseconds between poll cycles per worker. 0 means tight loop.")
        var intervalMs: Double = 0

        @Option(name: .long, help: "Number of unmeasured poll cycles to run per worker before collecting stats.")
        var warmupIterations: Int = 2

        @Flag(name: .long, help: "Also run the pollMessageUpdates-style query after unread-state polling.")
        var includeUpdates = false

        @Flag(name: .long, help: "Keep the updates cursor stale so --include-updates performs a worst-case scan each cycle.")
        var staleUpdatesCursor = false

        mutating func validate() throws {
            guard duration > 0 || iterations != nil else {
                throw ValidationError("Specify a positive --duration or --iterations.")
            }
            guard concurrency > 0 else {
                throw ValidationError("--concurrency must be greater than 0.")
            }
            if let iterations {
                guard iterations > 0 else {
                    throw ValidationError("--iterations must be greater than 0.")
                }
            }
            guard intervalMs >= 0 else {
                throw ValidationError("--interval-ms cannot be negative.")
            }
            guard warmupIterations >= 0 else {
                throw ValidationError("--warmup-iterations cannot be negative.")
            }
            guard !staleUpdatesCursor || includeUpdates else {
                throw ValidationError("--stale-updates-cursor only applies with --include-updates.")
            }
        }

        mutating func run() async throws {
            bootstrap(logLevel: logLevel)

            let benchmark = PollBenchmarkRunner(
                messagesDir: messagesDir,
                duration: duration,
                iterations: iterations,
                concurrency: concurrency,
                intervalMs: intervalMs,
                warmupIterations: warmupIterations,
                includeUpdates: includeUpdates,
                staleUpdatesCursor: staleUpdatesCursor
            )
            try await benchmark.run()
        }
    }
}

private struct PollBenchmarkRunner {
    struct Cursor {
        var lastRowID = 0
        var lastDateRead = Date(nanosecondsSinceReferenceDate: 0)
        var lastDateEdited = Date()
    }

    let messagesDir: String?
    let duration: Double
    let iterations: Int?
    let concurrency: Int
    let intervalMs: Double
    let warmupIterations: Int
    let includeUpdates: Bool
    let staleUpdatesCursor: Bool

    func run() async throws {
        let coordinator = PollBenchmarkCoordinator(
            duration: duration,
            maxIterations: iterations
        )
        let startGate = PollBenchmarkStartGate(workerCount: concurrency)
        let results = PollBenchmarkResults()

        print("poll benchmark")
        print("- query: IMDatabase.chatStates()" + (includeUpdates ? " + chats(withMessagesNewerThanRowID:orReadSince:orEditedSince:)" : ""))
        print("- messages dir: \(databaseDirectoryPath)")
        print("- duration: \(formatSeconds(duration))")
        print("- iterations cap: \(iterations.map(String.init) ?? "none")")
        print("- concurrency: \(concurrency)")
        print("- interval: \(formatMilliseconds(intervalMs))")
        print("- stale updates cursor: \(staleUpdatesCursor)")
        print()

        var cpuStart = ResourceUsage.now()
        var wallStart = DispatchTime.now().uptimeNanoseconds

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workerID in 0..<concurrency {
                group.addTask {
                    try await runWorker(
                        id: workerID,
                        coordinator: coordinator,
                        startGate: startGate,
                        results: results
                    )
                }
            }

            await startGate.waitUntilReady()
            cpuStart = ResourceUsage.now()
            wallStart = DispatchTime.now().uptimeNanoseconds
            await coordinator.start()
            await startGate.start()

            try await group.waitForAll()
        }

        let wallSeconds = secondsSince(wallStart)
        let cpuDelta = ResourceUsage.now() - cpuStart
        let snapshot = await results.snapshot()

        print()
        print(snapshot.summary(wallSeconds: wallSeconds, cpu: cpuDelta))
    }

    private var databaseDirectoryPath: String {
        guard let messagesDir else {
            return "~/Library/Messages"
        }
        return NSString(string: messagesDir).expandingTildeInPath
    }

    private func makeDatabase() throws -> IMDatabase {
        guard let messagesDir else {
            return try IMDatabase()
        }
        let url = URL(fileURLWithPath: NSString(string: messagesDir).expandingTildeInPath)
        return try IMDatabase(messagesDataBaseURL: url)
    }

    private func runWorker(
        id: Int,
        coordinator: PollBenchmarkCoordinator,
        startGate: PollBenchmarkStartGate,
        results: PollBenchmarkResults
    ) async throws {
        let db: IMDatabase
        var cursor = Cursor()

        do {
            db = try makeDatabase()
            for _ in 0..<warmupIterations {
                _ = try runPollCycle(db: db, cursor: &cursor)
            }
        } catch {
            await startGate.workerFailedBeforeStart()
            throw error
        }

        await startGate.workerReadyAndWait()

        let sleepNanoseconds = UInt64(intervalMs * 1_000_000)
        while let sequence = await coordinator.nextSequence() {
            do {
                let start = DispatchTime.now().uptimeNanoseconds
                let sample = try runPollCycle(db: db, cursor: &cursor)
                let elapsed = secondsSince(start)
                await results.record(workerID: id, sequence: sequence, duration: elapsed, sample: sample)
            } catch {
                await results.recordFailure()
                throw error
            }

            if sleepNanoseconds > 0 {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
    }

    private func runPollCycle(db: IMDatabase, cursor: inout Cursor) throws -> PollBenchmarkSample {
        let states = try db.chatStates()
        var updatedChatCount = 0

        if includeUpdates {
            let queryResult = try db.chats(
                withMessagesNewerThanRowID: cursor.lastRowID,
                orReadSince: cursor.lastDateRead,
                orEditedSince: cursor.lastDateEdited
            )
            updatedChatCount = queryResult.updatedChats.count

            if !staleUpdatesCursor {
                if let latestMessageRowID = queryResult.latestMessageRowID {
                    cursor.lastRowID = latestMessageRowID
                }
                if let latestMessageDateRead = queryResult.latestMessageDateRead {
                    cursor.lastDateRead = latestMessageDateRead
                }
                if let latestDateEdited = queryResult.latestDateEdited {
                    cursor.lastDateEdited = latestDateEdited
                }
            }
        }

        return PollBenchmarkSample(
            chatCount: states.count,
            unreadChatCount: states.values.filter { $0.unreadCount > 0 }.count,
            totalUnreadCount: states.values.reduce(0) { $0 + $1.unreadCount },
            updatedChatCount: updatedChatCount
        )
    }
}

private actor PollBenchmarkStartGate {
    private let workerCount: Int
    private var readyWorkers = 0
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations = [CheckedContinuation<Void, Never>]()
    private var hasStarted = false

    init(workerCount: Int) {
        self.workerCount = workerCount
    }

    func workerReadyAndWait() async {
        workerReady()

        await withCheckedContinuation { continuation in
            if hasStarted {
                continuation.resume()
            } else {
                startContinuations.append(continuation)
            }
        }
    }

    func workerFailedBeforeStart() {
        workerReady()
    }

    func waitUntilReady() async {
        guard readyWorkers < workerCount else { return }

        await withCheckedContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func start() {
        hasStarted = true
        let continuations = startContinuations
        startContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func workerReady() {
        readyWorkers += 1
        if readyWorkers >= workerCount {
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }
}

private actor PollBenchmarkCoordinator {
    private let duration: Double
    private var deadline: UInt64?
    private let maxIterations: Int?
    private var issuedIterations = 0

    init(duration: Double, maxIterations: Int?) {
        self.duration = duration
        self.maxIterations = maxIterations
    }

    func start() {
        guard deadline == nil, duration > 0 else { return }
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(duration * 1_000_000_000)
    }

    func nextSequence() -> Int? {
        start()

        if let maxIterations, issuedIterations >= maxIterations {
            return nil
        }

        if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
            return nil
        }

        issuedIterations += 1
        return issuedIterations
    }
}

private actor PollBenchmarkResults {
    private var durations: [Double] = []
    private var failures = 0
    private var lastSample: PollBenchmarkSample?

    func record(workerID _: Int, sequence _: Int, duration: Double, sample: PollBenchmarkSample) {
        durations.append(duration)
        lastSample = sample
    }

    func recordFailure() {
        failures += 1
    }

    func snapshot() -> PollBenchmarkSnapshot {
        PollBenchmarkSnapshot(
            durations: durations,
            failures: failures,
            lastSample: lastSample
        )
    }
}

private struct PollBenchmarkSample {
    let chatCount: Int
    let unreadChatCount: Int
    let totalUnreadCount: Int
    let updatedChatCount: Int
}

private struct PollBenchmarkSnapshot {
    let durations: [Double]
    let failures: Int
    let lastSample: PollBenchmarkSample?

    func summary(wallSeconds: Double, cpu: ResourceUsage) -> String {
        guard !durations.isEmpty else {
            return "no poll cycles completed; failures: \(failures)"
        }

        let sorted = durations.sorted()
        let totalDuration = durations.reduce(0, +)
        let mean = totalDuration / Double(durations.count)
        let cyclesPerSecond = Double(durations.count) / wallSeconds
        let cpuSeconds = cpu.userSeconds + cpu.systemSeconds
        let cpuCores = wallSeconds > 0 ? cpuSeconds / wallSeconds : 0

        var lines = [
            "results",
            "- poll cycles: \(durations.count)",
            "- failures: \(failures)",
            "- wall time: \(formatSeconds(wallSeconds))",
            "- throughput: \(formatDouble(cyclesPerSecond)) cycles/s",
            "- duration mean: \(formatMilliseconds(mean * 1_000))",
            "- duration p50: \(formatMilliseconds(percentile(0.50, in: sorted) * 1_000))",
            "- duration p95: \(formatMilliseconds(percentile(0.95, in: sorted) * 1_000))",
            "- duration p99: \(formatMilliseconds(percentile(0.99, in: sorted) * 1_000))",
            "- duration max: \(formatMilliseconds((sorted.last ?? 0) * 1_000))",
            "- cpu user/system/total: \(formatSeconds(cpu.userSeconds)) / \(formatSeconds(cpu.systemSeconds)) / \(formatSeconds(cpuSeconds))",
            "- approx cpu cores consumed: \(formatDouble(cpuCores))",
        ]

        if let lastSample {
            lines.append("- last sample: \(lastSample.chatCount) chats, \(lastSample.unreadChatCount) unread chats, \(lastSample.totalUnreadCount) unread messages, \(lastSample.updatedChatCount) updated chats")
        }

        return lines.joined(separator: "\n")
    }
}

private struct ResourceUsage {
    let userSeconds: Double
    let systemSeconds: Double

    static func now() -> ResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return ResourceUsage(
            userSeconds: seconds(from: usage.ru_utime),
            systemSeconds: seconds(from: usage.ru_stime)
        )
    }

    private static func seconds(from time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }

    static func - (lhs: ResourceUsage, rhs: ResourceUsage) -> ResourceUsage {
        ResourceUsage(
            userSeconds: lhs.userSeconds - rhs.userSeconds,
            systemSeconds: lhs.systemSeconds - rhs.systemSeconds
        )
    }
}

private func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let clampedPercentile = min(max(percentile, 0), 1)
    let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded(.up))
    return sorted[min(index, sorted.count - 1)]
}

private func secondsSince(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

private func formatSeconds(_ seconds: Double) -> String {
    "\(formatDouble(seconds))s"
}

private func formatMilliseconds(_ milliseconds: Double) -> String {
    "\(formatDouble(milliseconds))ms"
}

private func formatDouble(_ value: Double) -> String {
    String(format: "%.3f", value)
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
