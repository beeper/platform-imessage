import ArgumentParser
import AsyncAlgorithms
import Cool
import Foundation

@main
struct Coroner: AsyncParsableCommand {
    @Option(name: [.customShort("p"), .customLong("password")], help: "The password to use when authenticating with rageshake.beeper.com.")
    var rageshakePassword: String

    @Argument(help: "The URL of the Rageshake listing to examine.")
    var rageshakeURL: URL

    mutating func run() async throws {
        let rageshake = try Rageshake(at: rageshakeURL).orThrow("couldn't construct rageshake")
        let files = try await rageshake.listing(authenticatingWithPassword: rageshakePassword)
        let messages = try await collate(files, authenticatingWithPassword: rageshakePassword)
        print("collated \(messages.count.formatted()) log messages")

        for message in messages {
            let timeANSI = "\u{1b}[90m\u{1b}[3m"
            let blackANSI = "\u{1b}[30m"
            let resetANSI = "\u{1b}[0m"

            let text = message.text
                .replacing("[object Object]", with: "\(blackANSI)<object>\(resetANSI)")
            print("\(timeANSI)\(message.timestamp.formatted())\(resetANSI) \(text)")
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
