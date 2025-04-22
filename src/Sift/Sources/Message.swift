import Cool
import Foundation

struct Message {
    let timestamp: Date
    let text: Substring
    let level: Level = .default
    let origin: Origin
    var fields: [String: String] = [:]

    enum Origin: CaseIterable, Hashable, Equatable {
        case swift
        case rust
        case renderer
    }

    enum Level: CaseIterable, Hashable, Equatable, Comparable {
        case trace
        case debug
        case `default` // or "log"
        case warn
        case error
    }
}

private struct RustServerLogMessage: Decodable {
    struct Fields: Decodable {
        let message: String
    }

    let timestamp: Date
    let level: String
    let fields: [String: String]
    let target: String
}

extension Message {
    enum ParsingFormat {
        // 2025-04-16 20:09:36 +0000 [debug:sws.app-elements] getMainWindow took 22.185087203979492ms
        case swiftServer

        // [log] [2025-03-07T04:49:09.206Z] restoreChangedAppIcon: skipping because newAppPath doesn't exist:
        case rollingLogger

        // {"timestamp":"2025-04-02T02:10:06.277403Z","level":"DEBUG","fields":{"message":"finished polling message updates","chat_guids_with_new_messages":"[imsg##thread:8491862087819470531d11097af12a10040219cc1bc32903]"},"target":"rust_server::poller"}
        case rustServer
    }

    private static let jsonDecoder: JSONDecoder = with(JSONDecoder()) {
        $0.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(container.decode(String.self))
        }
    }

    init(parsing line: String, format: ParsingFormat) throws {
        switch format {
        case .swiftServer:
            let firstOpeningBracket = try line.firstIndex(of: "[").orThrow("couldn't find [")
            let unparsedDate = line[..<line.index(before: firstOpeningBracket) /* skip space */ ]

            // 2025-04-16 20:09:36 +0000
            timestamp = try Date.ISO8601FormatStyle()
                .year().month().day()
                .dateTimeSeparator(.space)
                .time(includingFractionalSeconds: false)
                .parse(String(unparsedDate))
            text = try line[line.index(line.firstIndex(of: "]").orThrow("couldn't find ]"), offsetBy: 2 /* skip space */ )...]
            origin = .swift
        case .rustServer:
            let message = try Self.jsonDecoder.decode(RustServerLogMessage.self, from: Data(line.utf8))
            timestamp = message.timestamp
            text = message.fields["message", default: "(...no message...)"][...]
            fields = message.fields.filter { $0.key != "message" }
            origin = .rust
        case .rollingLogger:
            // drop the first [ and search for the next [
            // (works because the indices remain unchanged)
            let dateLeftBracketIndex = try line.dropFirst().firstIndex(of: "[").orThrow("couldn't find date's [")
            let dateRightBracketIndex = try line.drop(while: { $0 != " " }).firstIndex(of: "]").orThrow("couldn't find date's ]")

            timestamp = try Date.ISO8601FormatStyle()
                .year().month().day()
                .time(includingFractionalSeconds: true)
                .parse(String(line[line.index(after: dateLeftBracketIndex) ..< dateRightBracketIndex]))
            let sourceReferenceIndex = try line.lastIndex(of: "(").orThrow("couldn't find source reference's (")
            text = line[line.index(dateRightBracketIndex, offsetBy: 2 /* skip space */ ) ..< sourceReferenceIndex]
            origin = .renderer
        }
    }
}
