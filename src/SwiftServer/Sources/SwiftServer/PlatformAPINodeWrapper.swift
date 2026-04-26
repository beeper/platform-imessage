import Foundation
import NodeAPI
import SwiftServerFoundation

@NodeActor @NodeClass final class PlatformAPINodeWrapper {
    static let name = "PlatformAPI"

    private let api: PlatformAPI

    @NodeConstructor init(accountID: String) {
        api = PlatformAPI(accountID: accountID, runtime: Self.makeRuntime())
    }

    @NodeMethod func getCurrentUser() async throws -> String {
        try await api.getCurrentUser()
    }

    @NodeMethod func searchMessages(typed: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        try await api.searchMessages(typed: typed, threadID: threadID, mediaOnly: mediaOnly, sender: sender, limit: limit)
    }

    @NodeMethod func getThreads(folderName: String, cursor: String?, direction: String?) async throws -> String {
        try await api.getThreads(folderName: folderName, cursor: cursor, direction: direction)
    }

    @NodeMethod func getMessages(threadID: String, cursor: String?, direction: String?, limit: Int?) async throws -> String {
        try await api.getMessages(threadID: threadID, cursor: cursor, direction: direction, limit: limit)
    }

    @NodeMethod func getThread(threadID: String) async throws -> String {
        try await api.getThread(threadID: threadID)
    }

    @NodeMethod func getMessage(threadID: String, messageID: String) async throws -> String {
        try await api.getMessage(threadID: threadID, messageID: messageID)
    }

    @NodeMethod func createThread(userIDs userIDsValue: NodeArray, title: String?, messageText: String?) async throws -> String {
        let userIDs = try userIDsValue.as([String].self).orThrow(ErrorMessage("Bad PlatformAPI call: \(#function)"))
        return try await api.createThread(userIDs: userIDs, title: title, messageText: messageText)
    }

    @NodeMethod func updateThread(threadID: String, muted: Bool) async throws {
        try await api.updateThread(threadID: threadID, muted: muted)
    }

    @NodeMethod func deleteThread(threadID: String) async throws {
        try await api.deleteThread(threadID: threadID)
    }

    @NodeMethod func sendMessage(threadID: String, text: String?, filePath: String?, quotedMessageID: String?) async throws -> String {
        try await api.sendMessage(threadID: threadID, text: text, filePath: filePath, quotedMessageID: quotedMessageID)
    }

    @NodeMethod func sendFileFromBuffer(threadID: String, fileBuffer: Data, fileName: String?, quotedMessageID: String?) async throws -> String {
        try await api.sendFileFromBuffer(threadID: threadID, fileBuffer: fileBuffer, fileName: fileName, quotedMessageID: quotedMessageID)
    }

    @NodeMethod func editMessage(threadID: String, messageID: String, content: String?) async throws {
        try await api.editMessage(threadID: threadID, messageID: messageID, content: content)
    }

    @NodeMethod func sendActivityIndicator(type: String, threadID: String?, sendingMessagesCount: Int?) async throws {
        try await api.sendActivityIndicator(type: type, threadID: threadID, sendingMessagesCount: sendingMessagesCount)
    }

    @NodeMethod func deleteMessage(threadID: String, messageID: String) async throws {
        try await api.deleteMessage(threadID: threadID, messageID: messageID)
    }

    @NodeMethod func sendReadReceipt(threadID: String) async throws {
        try await api.sendReadReceipt(threadID: threadID)
    }

    @NodeMethod func addReaction(threadID: String, messageID: String, reactionKey: String) async throws {
        try await api.addReaction(threadID: threadID, messageID: messageID, reactionKey: reactionKey)
    }

    @NodeMethod func removeReaction(threadID: String, messageID: String, reactionKey: String) async throws {
        try await api.removeReaction(threadID: threadID, messageID: messageID, reactionKey: reactionKey)
    }

    @NodeMethod func setReaction(threadID: String, messageID: String, reaction: String, on: Bool) async throws {
        try await api.setReaction(threadID: threadID, messageID: messageID, reaction: reaction, on: on)
    }

    @NodeMethod func markAsUnread(threadID: String) async throws {
        try await api.markAsUnread(threadID: threadID)
    }

    @NodeMethod func notifyAnyway(threadID: String) async throws {
        try await api.notifyAnyway(threadID: threadID)
    }

    @NodeMethod func onThreadSelected(_ args: NodeArguments) async throws {
        guard args.count == 2,
              let threadID = try args[0].as(String.self),
              let sendEvents = try args[1].as(NodeFunction.self)
        else {
            throw ErrorMessage("Bad PlatformAPI call: \(#function)")
        }

        try await api.onThreadSelected(threadID: threadID) { events in
            try NodeActor.unsafeAssumeIsolated {
                _ = try sendEvents.dynamicallyCall(withArguments: [try NodeBridgeUtilities.nodeArray(from: events)])
            }
        }
    }

    @NodeMethod func getAsset(pathHex: String, methodName: String?) async throws -> NodeValueConvertible {
        switch try await api.getAsset(pathHex: pathHex, methodName: methodName) {
        case let .url(url):
            return url
        case let .data(data):
            return data
        }
    }

    @NodeMethod func dispose() async throws {
        try await api.dispose()
    }

    private static func makeRuntime() -> PlatformAPIRuntime {
        let sentryQueue = try? NodeAsyncQueue(label: "platform-api-sentry")
        return PlatformAPIRuntime(
            makeCallbackQueue: { label in
                try NodeActor.unsafeAssumeIsolated {
                    let queue = try NodeAsyncQueue(label: label)
                    return PlatformCallbackQueue { action in
                        try queue.run(action)
                    }
                }
            },
            reportMessageToSentry: { message in
                try sentryQueue?.run {
                    try Node.texts.Sentry.captureMessage(message)
                }
            },
            addCleanupHook: { action in
                try NodeActor.unsafeAssumeIsolated {
                    let hook = try NodeEnvironment.current.addCleanupHook { completion in
                        action(completion)
                    }
                    return PlatformCleanupHook {
                        try NodeActor.unsafeAssumeIsolated {
                            try NodeEnvironment.current.removeCleanupHook(hook)
                        }
                    }
                }
            }
        )
    }
}
