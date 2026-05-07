import ArgumentParser
import Foundation
import IMDatabase
import IMessage

enum BenchmarkFormat: String, ExpressibleByArgument {
    case json
    case pretty

    init?(argument: String) {
        self.init(rawValue: argument)
    }
}

struct BenchmarkMetadata: Encodable {
    let messagesDir: String
    let iterations: Int
    let warmups: Int
    let maxChats: Int
    let messageLimit: Int
    let apiThreadSamples: Int
    let searchQuery: String
    let createIndexes: Bool
    let sqlIncluded: Bool
    let apiIncluded: Bool
}

struct BenchmarkSection: Encodable {
    let skipped: Bool
    let results: [BenchmarkResult]
}

struct BenchmarkResult: Encodable {
    let name: String
    let resultCount: Int
    let iterations: Int
    let warmups: Int
    let samplesMS: [Double]
    let averageMS: Double
    let p50MS: Double
    let p95MS: Double
    let minMS: Double
    let maxMS: Double
}

struct BenchmarkReport: Encodable {
    let metadata: BenchmarkMetadata
    let sql: BenchmarkSection
    let api: BenchmarkSection
}

struct SQLSample {
    let threadRows: [MappedChatRow]
    let messageChatGUIDs: [String]
    let messageRows: [MappedMessageRow]

    var chatRowIDs: [Int] {
        threadRows.map(\.rowID)
    }

    var messageRowIDs: [Int] {
        messageRows.map(\.rowID)
    }

    var messageGUIDs: [String] {
        messageRows.map(\.guid)
    }

    var messageChatRowIDs: [Int] {
        Array(Set(messageRows.compactMap(\.chatRowID))).sorted()
    }
}

enum BenchError: Error, CustomStringConvertible {
    case noThreads
    case invalidOption(String)

    var description: String {
        switch self {
        case .noThreads:
            return "No iMessage threads were found in the selected Messages database."
        case let .invalidOption(message):
            return message
        }
    }
}

@main
struct IMessagePerfBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Benchmark iMessage database and API read paths without depending on a specific SQL backend."
    )

    @Option(help: "Messages data directory. Defaults to ~/Library/Messages.")
    var messagesDir: String = "~/Library/Messages"

    @Option(help: "Measured iterations per benchmark case.")
    var iterations: Int = 7

    @Option(help: "Warmup iterations per benchmark case.")
    var warmups: Int = 2

    @Option(help: "Maximum chats to sample for SQL benchmarks.")
    var maxChats: Int = 10

    @Option(help: "Maximum messages per sampled chat.")
    var messageLimit: Int = 50

    @Option(help: "Maximum threads to sample for PlatformAPI.getMessages.")
    var apiThreadSamples: Int = 5

    @Option(help: "Search text for searchMessages benchmarks.")
    var searchQuery: String = "a"

    @Flag(help: "Ask IMDatabase to create its optional read indexes before benchmarking.")
    var createIndexes = false

    @Flag(help: "Only run IMDatabase SQL hot path benchmarks.")
    var sqlOnly = false

    @Flag(help: "Only run final PlatformAPI.getThreads/getMessages benchmarks.")
    var apiOnly = false

    @Option(help: "Output format.")
    var format: BenchmarkFormat = .json

    mutating func run() async throws {
        try validateOptions()

        let messagesURL = expandTilde(in: messagesDir)
        let includeSQL = !apiOnly
        let includeAPI = !sqlOnly

        let sqlResults = includeSQL
            ? try runSQLBenchmarks(messagesURL: messagesURL)
            : []
        let apiResults = includeAPI
            ? try await runAPIBenchmarks()
            : []

        let report = BenchmarkReport(
            metadata: BenchmarkMetadata(
                messagesDir: messagesURL.path,
                iterations: iterations,
                warmups: warmups,
                maxChats: maxChats,
                messageLimit: messageLimit,
                apiThreadSamples: apiThreadSamples,
                searchQuery: searchQuery,
                createIndexes: createIndexes,
                sqlIncluded: includeSQL,
                apiIncluded: includeAPI
            ),
            sql: BenchmarkSection(skipped: !includeSQL, results: sqlResults),
            api: BenchmarkSection(skipped: !includeAPI, results: apiResults)
        )

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        case .pretty:
            printPretty(report)
        }
    }

    private func validateOptions() throws {
        if iterations <= 0 {
            throw BenchError.invalidOption("--iterations must be greater than zero.")
        }
        if warmups < 0 {
            throw BenchError.invalidOption("--warmups must be zero or greater.")
        }
        if maxChats <= 0 {
            throw BenchError.invalidOption("--max-chats must be greater than zero.")
        }
        if messageLimit <= 0 {
            throw BenchError.invalidOption("--message-limit must be greater than zero.")
        }
        if apiThreadSamples <= 0 {
            throw BenchError.invalidOption("--api-thread-samples must be greater than zero.")
        }
        if sqlOnly && apiOnly {
            throw BenchError.invalidOption("--sql-only and --api-only cannot both be set.")
        }
    }

    private func runSQLBenchmarks(messagesURL: URL) throws -> [BenchmarkResult] {
        let db = try IMDatabase(messagesDataBaseURL: messagesURL, createIndexes: createIndexes)
        let sample = try makeSQLSample(db: db)
        var results: [BenchmarkResult] = []

        results.append(try measure("mappedThreadRows") {
            try db.mappedThreadRows(cursor: nil, direction: nil, limit: maxChats).count
        })
        results.append(try measure("mappedLatestMessageRows") {
            try db.mappedLatestMessageRows(chatRowIDs: sample.chatRowIDs).count
        })
        results.append(try measure("mappedThreadParticipantRows") {
            try db.mappedThreadParticipantRows(chatRowIDs: sample.chatRowIDs).values.reduce(0) { $0 + $1.count }
        })
        results.append(try measure("mappedUnreadCounts") {
            try db.mappedUnreadCounts(chatRowIDs: sample.chatRowIDs).count
        })
        results.append(try measure("mappedMessageRows.page") {
            var count = 0
            for chatGUID in sample.messageChatGUIDs {
                count += try db.mappedMessageRows(in: chatGUID, cursor: nil, direction: nil, limit: messageLimit).count
            }
            return count
        })
        results.append(try measure("mappedMessageRows.rowIDs") {
            try db.mappedMessageRows(rowIDs: sample.messageRowIDs).count
        })
        results.append(try measure("mappedMessageRows.guids") {
            try db.mappedMessageRows(guids: sample.messageGUIDs).count
        })
        results.append(try measure("mappedAttachmentRows") {
            try db.mappedAttachmentRows(messageRowIDs: sample.messageRowIDs).count
        })
        results.append(try measure("mappedReactionRows") {
            try db.mappedReactionRows(messageGUIDs: sample.messageGUIDs, chatRowIDs: sample.messageChatRowIDs).count
        })
        results.append(try measure("messageUpdateCursorSnapshot") {
            try db.messageUpdateCursorSnapshot().lastRowID
        })
        results.append(try measure("chatStates") {
            try db.chatStates().count
        })
        results.append(try measure("searchMessages") {
            try db.searchMessages(query: searchQuery, limit: messageLimit).count
        })

        return results
    }

    private func makeSQLSample(db: IMDatabase) throws -> SQLSample {
        let threadRows = try db.mappedThreadRows(cursor: nil, direction: nil, limit: maxChats)
        guard !threadRows.isEmpty else {
            throw BenchError.noThreads
        }

        var messageChatGUIDs: [String] = []
        var messageRows: [MappedMessageRow] = []
        for threadRow in threadRows {
            let rows = try db.mappedMessageRows(in: threadRow.guid, cursor: nil, direction: nil, limit: messageLimit)
            guard !rows.isEmpty else { continue }
            messageChatGUIDs.append(threadRow.guid)
            messageRows.append(contentsOf: rows)
        }

        return SQLSample(
            threadRows: threadRows,
            messageChatGUIDs: messageChatGUIDs,
            messageRows: messageRows
        )
    }

    private func runAPIBenchmarks() async throws -> [BenchmarkResult] {
        let api = try PlatformAPI(accountID: "perf-bench", enforceSingleton: false)
        do {
            let threadPage = try await api.getThreads(folderName: "normal", pagination: nil)
            let threadIDs = Array(threadPage.items.prefix(apiThreadSamples).map(\.id))
            guard !threadIDs.isEmpty else {
                throw BenchError.noThreads
            }

            var results: [BenchmarkResult] = []
            results.append(try await measureAsync("PlatformAPI.getThreads.firstPage") {
                try await api.getThreads(folderName: "normal", pagination: nil).items.count
            })
            results.append(try await measureAsync("PlatformAPI.getMessages.sampleThreads") {
                var count = 0
                for threadID in threadIDs {
                    count += try await api.getMessages(threadID: threadID, pagination: nil).items.count
                }
                return count
            })
            try? await api.dispose()
            return results
        } catch {
            try? await api.dispose()
            throw error
        }
    }

    private func measure(_ name: String, operation: () throws -> Int) throws -> BenchmarkResult {
        for _ in 0..<warmups {
            _ = try operation()
        }

        var samples: [Double] = []
        var resultCount = 0
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            resultCount = try operation()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(milliseconds(fromNanoseconds: end - start))
        }

        return BenchmarkResult(
            name: name,
            resultCount: resultCount,
            iterations: iterations,
            warmups: warmups,
            samplesMS: samples,
            averageMS: average(samples),
            p50MS: percentile(samples, 0.50),
            p95MS: percentile(samples, 0.95),
            minMS: samples.min() ?? 0,
            maxMS: samples.max() ?? 0
        )
    }

    private func measureAsync(_ name: String, operation: () async throws -> Int) async throws -> BenchmarkResult {
        for _ in 0..<warmups {
            _ = try await operation()
        }

        var samples: [Double] = []
        var resultCount = 0
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            resultCount = try await operation()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(milliseconds(fromNanoseconds: end - start))
        }

        return BenchmarkResult(
            name: name,
            resultCount: resultCount,
            iterations: iterations,
            warmups: warmups,
            samplesMS: samples,
            averageMS: average(samples),
            p50MS: percentile(samples, 0.50),
            p95MS: percentile(samples, 0.95),
            minMS: samples.min() ?? 0,
            maxMS: samples.max() ?? 0
        )
    }
}

private func expandTilde(in path: String) -> URL {
    let expandedPath: String
    if path == "~" {
        expandedPath = NSHomeDirectory()
    } else if path.hasPrefix("~/") {
        expandedPath = NSHomeDirectory() + String(path.dropFirst())
    } else {
        expandedPath = path
    }
    return URL(fileURLWithPath: expandedPath, isDirectory: true)
}

private func milliseconds(fromNanoseconds nanoseconds: UInt64) -> Double {
    Double(nanoseconds) / 1_000_000
}

private func average(_ samples: [Double]) -> Double {
    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0, +) / Double(samples.count)
}

private func percentile(_ samples: [Double], _ percentile: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1))
    return sorted[index]
}

private func printPretty(_ report: BenchmarkReport) {
    print("iMessage perf benchmark")
    print("Messages dir: \(report.metadata.messagesDir)")
    print("Iterations: \(report.metadata.iterations), warmups: \(report.metadata.warmups)")
    print()
    printSection("SQL hot paths", report.sql.results)
    print()
    printSection("Platform API", report.api.results)
}

private func printSection(_ title: String, _ results: [BenchmarkResult]) {
    guard !results.isEmpty else {
        print("\(title): skipped")
        return
    }

    print(title)
    print("\(pad("name", to: 40)) \(pad("rows", to: 8)) \(pad("avg ms", to: 10)) \(pad("p50 ms", to: 10)) \(pad("p95 ms", to: 10))")
    for result in results {
        let row = [
            pad(result.name, to: 40),
            pad(String(result.resultCount), to: 8),
            pad(String(format: "%.3f", result.averageMS), to: 10),
            pad(String(format: "%.3f", result.p50MS), to: 10),
            pad(String(format: "%.3f", result.p95MS), to: 10),
        ].joined(separator: " ")
        print(row)
    }
}

private func pad(_ value: String, to width: Int) -> String {
    let trimmed = value.count > width ? String(value.prefix(width - 1)) + "*" : value
    return trimmed + String(repeating: " ", count: max(0, width - trimmed.count))
}
