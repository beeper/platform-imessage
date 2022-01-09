import Foundation

enum MessagesDeepLink {
    case addresses([String], body: String?)
    case group(chatID: String, body: String?)
    // case message(guid: String)
    case message(guid: String, overlay: Bool?)

    static let compose: MessagesDeepLink = .addresses([], body: nil)

    init(threadID: String, body: String?) throws {
        let components = threadID.split(separator: ";", maxSplits: 2)
        let (_, type, id) = (components[0], components[1], components[2])
        if type == "-" {
            self = .addresses([String(id)], body: body)
        } else if type == "+" {
            self = .group(chatID: String(id), body: body)
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
        case let .message(guid, overlay):
            components.queryItems = [
                URLQueryItem(name: "message-guid", value: guid)
            ]
            if overlay == true {
                components.queryItems?.append(URLQueryItem(name: "overlay", value: "1"))
            }
            return try components.url.orThrow(ErrorMessage("Invalid message GUID: \(guid)"))
        }
    }
}
