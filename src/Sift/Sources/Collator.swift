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
    static let reallyBlueBackground = "\u{1b}[48;2;0;0;255m"
    static let reallyPurpleBackground = "\u{1b}[48;2;128;0;255m"
    static let brightWhite = "\u{1b}[97m"
    static let reset = "\u{1b}[0m"
    static let reverse = "\u{1b}[7m"
}

@main
struct Collator: AsyncParsableCommand {
    @Option(name: [.customShort("p"), .customLong("password")], help: "The password to use when authenticating with rageshake.beeper.com.")
    var rageshakePassword: String

    @Argument(help: "The URL of the Rageshake listing to examine.")
    var rageshakeURL: URL

    @Option(help: "Only displays messages containing this text. Messages' fields are examined in addition to the main message text.")
    var grep: String?

    @Flag(name: [.customShort("i"), .customLong("intermissions")], inversion: .prefixedNo, help: "Whether to display intermissions.")
    var displayingIntermissions: Bool = true

    @Option(name: [.customShort("I"), .customLong("intermission-time")], help: "The minimum difference of log message timestamp (in seconds) before an intermission is displayed.")
    var intermissionTimeSeconds: Double = 30.0

    mutating func run() async throws {
        let rageshake = try Rageshake(at: rageshakeURL).orThrow("couldn't construct rageshake")
        let files = try await rageshake.listing(authenticatingWithPassword: rageshakePassword)
        let messages = try await collate(files, authenticatingWithPassword: rageshakePassword)
        print("collated \(messages.count.formatted()) log messages")

        var lastTimestamp: Date?
        for message in messages {
            printMessage(rendering: message, lastTimestamp: &lastTimestamp)
        }
    }

    func printMessage(rendering message: Message, lastTimestamp: inout Date?) {
        if let grep, !message.contains(grep), message.landmark == nil { return }

        defer { lastTimestamp = message.timestamp }

        if displayingIntermissions,
           let lastTimestamp,
           case let delta = lastTimestamp.distance(to: message.timestamp),
           delta > intermissionTimeSeconds
        {
            printIntermission(delta: Duration.seconds(delta))
        }

        print(message.render())
    }

    private func printIntermission(delta: Duration) {
        print()
        print(" ⋮")
        let formattedDelta = delta
            .formatted(.units(allowed: [.milliseconds, .seconds, .minutes, .hours, .days], width: .abbreviated))
        print(" ⋮ \(ANSI.bold)(\(formattedDelta) later...)\(ANSI.reset)")
        print(" ⋮")
        print()
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

private enum Landmark {
    case systemWakeStateChanged
    case appLaunching
    case rageshakeSubmitting

    var ansiColoration: String {
        switch self {
        case .systemWakeStateChanged: ANSI.reallyBlueBackground
        case .appLaunching: ANSI.reallyRedBackground
        case .rageshakeSubmitting: ANSI.reallyPurpleBackground
        }
    }
}

private extension Message {
    func contains(_ needle: String) -> Bool {
        text.contains(needle) || fields.contains(where: { $0.value.contains(needle) })
    }

    var landmark: Landmark? {
        switch true {
        case contains("SLEEP: "): .systemWakeStateChanged
        case contains("You're running"): .appLaunching
        case contains("Submitting bug report"): .rageshakeSubmitting
        default: nil
        }
    }

    func render() -> String {
        let text = text
            .replacing("[object Object]", with: "\(ANSI.black)<object>\(ANSI.reset)")

        var fields: String = fields
            .map { key, value in "\(ANSI.black)\(ANSI.italic)\(key)\(ANSI.reset)\(ANSI.black): \(value)\(ANSI.reset)" }
            .joined(separator: "\(ANSI.black), \(ANSI.reset)")
        fields = fields.isEmpty ? "" : " \(fields)"

        var rendered: String
        if let landmark {
            rendered = "\(timestamp.formattedForCollation) \(text)\(fields)"
            // this is technically incorrect because it counts grapheme clusters and not terminal cells
            // also, make sure to count before adding the color codes, so they don't affect it
            if let width = Terminal.size?.width {
                rendered += String(repeating: " ", count: width - rendered.count)
            }
            rendered = "\(ANSI.bold)\(ANSI.brightWhite)\(landmark.ansiColoration)\(rendered)\(ANSI.reset)"
        } else {
            rendered = "\(ANSI.time)\(timestamp.formattedForCollation)\(ANSI.reset) \(text)\(fields)"
        }

        return rendered
    }
}

private extension Date {
    var formattedForCollation: String {
        let formatStyle = Date.FormatStyle()
            .weekday(.abbreviated).month(.abbreviated).day()
            .hour().minute().second().secondFraction(.fractional(3))
        return formatted(formatStyle)
    }
}

private extension RageshakeFile {
    private static let cachePath: URL = {
        let caches = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return caches / "com.automattic.beeper.desktop.sift"
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
        let (bytes, response_) = try await URLSession.rageshake.bytes(for: request)
        let response = response_ as! HTTPURLResponse
        guard (200 ..< 300).contains(response.statusCode) else {
            throw Rageshake.Error.http(response)
        }
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
