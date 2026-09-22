import Foundation
import IMessageCore

struct MessagesDeepLink {
    private enum Destination {
        case addresses([String], body: String?)
        case group(chatID: String, body: String?)
        case message(guid: String, partIndex: Int?, overlay: Bool?)
    }

    private let destination: Destination
    let targetThreadID: String?

    static let compose = MessagesDeepLink.addresses([], body: nil)

    init(threadID: String, body: String?) throws {
        let (_, type, id) = try splitThreadID(threadID).orThrow(ErrorMessage("invalid threadID: \(threadID)"))
        switch type {
        case Self.singleThreadType:
            self.init(destination: .addresses([String(id)], body: body), targetThreadID: threadID)
        case Self.groupThreadType:
            self.init(destination: .group(chatID: String(id), body: body), targetThreadID: threadID)
        default:
            throw ErrorMessage("invalid threadID: \(threadID)")
        }
    }

    static func addresses(_ addresses: [String], body: String?) -> Self {
        Self(destination: .addresses(addresses, body: body), targetThreadID: nil)
    }

    static func group(chatID: String, body: String?) -> Self {
        Self(destination: .group(chatID: chatID, body: body), targetThreadID: nil)
    }

    static func message(guid: String, partIndex: Int?, overlay: Bool?, threadID: String? = nil) -> Self {
        Self(destination: .message(guid: guid, partIndex: partIndex, overlay: overlay), targetThreadID: threadID)
    }

    private init(destination: Destination, targetThreadID: String?) {
        self.destination = destination
        self.targetThreadID = targetThreadID
    }

    func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"

        switch destination {
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
        case let .message(guid, partIndex, overlay):
            guard !guid.contains("_") else { throw ErrorMessage("Invalid message GUID, contains _: \(guid)") }
            components.queryItems = [
                // p:0/GUID and GUID are equivalent
                URLQueryItem(name: "message-guid", value: partIndex.map { "p:\($0)/\(guid)" } ?? guid)
            ]
            if overlay == true {
                components.queryItems?.append(URLQueryItem(name: "overlay", value: "1"))
            }
            return try components.url.orThrow(ErrorMessage("Invalid message GUID: \(guid)"))
        }
    }
}

extension MessagesDeepLink {
    static let singleThreadType = "-"
    static let groupThreadType = "+"
}
