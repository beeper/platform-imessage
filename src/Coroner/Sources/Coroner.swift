import ArgumentParser
import AsyncAlgorithms
import Cool
import Foundation

enum ANSI {
    static let italic = "\u{1b}[3m"
    static let time = "\u{1b}[90m\(italic)"
    static let black = "\u{1b}[30m"
    static let bold = "\u{1b}[1m"
    static let red = "\u{1b}[31m"
    static let reallyRedBackground = "\u{1b}[48;2;255;0;0m"
    static let brightWhite = "\u{1b}[97m"
    static let reset = "\u{1b}[0m"
    static let reverse = "\u{1b}[7m"
}

@main
struct Coroner: AsyncParsableCommand {
    @Option(name: [.customShort("p"), .customLong("password")], help: "The password to use when authenticating with rageshake.beeper.com.")
    var rageshakePassword: String

    @Argument(help: "The URL of the Rageshake listing to examine.")
    var rageshakeURL: URL

    @Option(help: "Only displays messages containing this text.")
    var grep: String?

    @Option(name: [.short, .customLong("intermission-time")], help: "The minimum amount of time (in seconds) before an intermission is emitted in the output.")
    var intermissionTimeSeconds: Double = 60.0

    mutating func run() async throws {
        let rageshake = try Rageshake(at: rageshakeURL).orThrow("couldn't construct rageshake")
        let files = try await rageshake.listing(authenticatingWithPassword: rageshakePassword)
        let messages = try await collate(files, authenticatingWithPassword: rageshakePassword)
        print("collated \(messages.count.formatted()) log messages")

        var lastTimestamp: Date?
        for message in messages {
            var isLandmark = false
            let messageContains = { (text: String) -> Bool in
                message.text.contains(text) || message.fields.contains(where: { $0.value.contains(text) })
            }

            isLandmark = messageContains("SLEEP: ")
            if let grep, !messageContains(grep), !isLandmark { continue }

            defer { lastTimestamp = message.timestamp }

            let text = message.text
                .replacing("[object Object]", with: "\(ANSI.black)<object>\(ANSI.reset)")
            let dateTimeFormat = Date.FormatStyle()
                .weekday(.abbreviated).month(.abbreviated).day()
                .hour().minute().second().secondFraction(.fractional(3))

            if let lastTimestamp, case let delta = lastTimestamp.distance(to: message.timestamp), delta > intermissionTimeSeconds {
                print()
                print(" ⋮")
                let formattedDelta = Duration.seconds(delta)
                    .formatted(.units(allowed: [.milliseconds, .seconds, .minutes, .hours, .days], width: .abbreviated))
                print(" ⋮ \(ANSI.bold)(\(formattedDelta) later...)\(ANSI.reset)")
                print(" ⋮")
                print()
            }

            var fields: String = message.fields
                .map { key, value in "\(ANSI.black)\(ANSI.italic)\(key)\(ANSI.reset)\(ANSI.black): \(value)\(ANSI.reset)" }
                .joined(separator: "\(ANSI.black), \(ANSI.reset)")
            fields = fields.isEmpty ? "" : " \(fields)"

            var renderedMessage: String
            if isLandmark {
                renderedMessage = "\(message.timestamp.formatted(dateTimeFormat)) \(text)\(fields)"
                // this is technically incorrect because it counts grapheme clusters and not terminal cells
                // also, make sure to count before adding the color codes, so they don't affect it
                renderedMessage += String(repeating: " ", count: Terminal.size!.width - renderedMessage.count)
                renderedMessage = "\(ANSI.bold)\(ANSI.brightWhite)\(ANSI.reallyRedBackground)\(renderedMessage)\(ANSI.reset)"
            } else {
                renderedMessage = "\(ANSI.time)\(message.timestamp.formatted(dateTimeFormat))\(ANSI.reset) \(text)\(fields)"
                print(renderedMessage)
            }
            print(renderedMessage)
        }
    }
}

private func collate(_ files: [RageshakeFile], authenticatingWithPassword rageshakePassword: String) async throws -> [Message] {
    let filesDictionary = Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0) })

    let filesToExamine = [
        "platform-imessage-poller.log.gz",
        "platform-imessage.log.gz",
        "renderer.log.gz",
    ]

    // copy so the command struct isn't captured by the escaping task group closure
    let logs = try await withThrowingTaskGroup(of: [Message].self) { group in
        for fileToExamine in filesToExamine {
            print("ingesting \(fileToExamine)")
            _ = group.addTaskUnlessCancelled {
                let file = try filesDictionary[fileToExamine].orThrow("rageshake doesn't contain \(fileToExamine)")
                var logs = [Message]()
                for try await line in try await file.lines(authenticatingWithPassword: rageshakePassword) {
                    guard !Task.isCancelled else { return [] }
                    try logs.append(Message(parsing: line, format: .init(rageshakeFilename: fileToExamine)))
                }

                return logs
            }
        }

        var allLogs = [Message]()
        for try await logs in group {
            allLogs.append(contentsOf: logs)
        }
        return allLogs
    }

    return logs.sorted(by: { $0.timestamp < $1.timestamp })
}

private extension RageshakeFile {
    private static let cachePath: URL = {
        let caches = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches / "com.automattic.beeper.desktop.coroner"
    }()

    func lines(authenticatingWithPassword rageshakePassword: String, caching: Bool = true) async throws -> any AsyncSequence<String, any Error> {
        let cacheEntryFileName = "\(parent.date)_\(parent.id)_\(fileName)"
        let cacheEntryURL = Self.cachePath / cacheEntryFileName

        if caching {
            // try to use the cached version
            try FileManager.default.createDirectory(at: Self.cachePath, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cacheEntryURL.path(percentEncoded: false)) {
                return cacheEntryURL.resourceBytes.lines
            }
        }

        let request = URLRequest.rageshakeBasicAuthenticated(for: url(authenticatingWith: .basic), withPassword: rageshakePassword)
        let (bytes, response) = try await URLSession.rageshake.bytes(for: request)
        if caching {
            let data = try await Data(bytes)
            try data.write(to: cacheEntryURL)
            // re-use the code path above
            return try await lines(authenticatingWithPassword: rageshakePassword, caching: true)
        } else {
            return bytes.lines
        }
    }
}

private extension Message.ParsingFormat {
    init(rageshakeFilename: String) {
        switch rageshakeFilename {
        case "platform-imessage-poller.log.gz": self = .rustServer
        case "platform-imessage.log.gz": self = .swiftServer
        default: self = .rollingLogger
        }
    }
}

extension URL: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(string: argument)
    }
}
