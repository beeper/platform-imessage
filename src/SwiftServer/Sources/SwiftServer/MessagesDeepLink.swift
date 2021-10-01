import Foundation

enum MessagesDeepLink {
    private static let groupPrefix = "iMessage;+;"
    private static let singlePrefix = "iMessage;-;"

    case addresses([String], body: String?)
    case group(chatID: String, body: String?)
    case message(guid: String)

    static let compose: MessagesDeepLink = .addresses([], body: nil)

    init(threadID: String, body: String?) throws {
        if threadID.hasPrefix(Self.singlePrefix) {
            self = .addresses([String(threadID.dropFirst(Self.singlePrefix.count))], body: body)
        } else if threadID.hasPrefix(Self.groupPrefix) {
            self = .group(chatID: String(threadID.dropFirst(Self.groupPrefix.count)), body: body)
        } else {
            throw ErrorMessage("Invalid thread ID: \(threadID)")
        }
    }

    func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"
        switch self {
        case let .addresses(addrs, body):
            components.queryItems = [
                URLQueryItem(
                    name: addrs.count < 2 ? "address" : "addresses",
                    value: addrs.joined(separator: ",")
                ),
                URLQueryItem(name: "body", value: body)
            ]
            return try components.url.orThrow(ErrorMessage("Invalid iMessage addresses: \(addrs)"))
        case let .group(chatID, body):
            components.queryItems = [
                URLQueryItem(
                    name: "groupid",
                    value: chatID
                ),
                URLQueryItem(name: "body", value: body)
            ]
            return try components.url.orThrow(ErrorMessage("Invalid iMessage chat: \(chatID)"))
        case let .message(guid):
            components.queryItems = [
                URLQueryItem(name: "message-guid", value: guid)
            ]
            return try components.url.orThrow(ErrorMessage("Invalid message GUID: \(guid)"))
        }
    }
}
