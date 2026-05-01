import Foundation
import NodeAPI
import IMessage
import IMessageCore
import PlatformSDK

@NodeActor @NodeClass final class PlatformAPINodeWrapper {
    private let api: PlatformAPI
    private var cleanupHook: AsyncCleanupHook?

    @NodeConstructor init(accountID: String) throws {
        let sentryQueue = try? NodeAsyncQueue(label: "platform-api-sentry")
        api = try PlatformAPI(accountID: accountID, reportErrorMessage: { message in
            try sentryQueue?.run {
                try Node.texts.Sentry.captureMessage(message)
            }
        })
        let api = SendableBox(api)
        cleanupHook = try? NodeEnvironment.current.addCleanupHook { completion in
            Task {
                try? await api.value.dispose()
                completion()
            }
        }
    }

    @NodeMethod func getCurrentUser() async throws -> String {
        let currentUser = try await api.getCurrentUser()
        return try encodeJSON(currentUser.jsonObject)
    }

    @NodeMethod func searchMessages(typed: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        let messages = try await api.searchMessages(typed: typed, threadID: threadID, mediaOnly: mediaOnly, sender: sender, limit: limit)
        return try encodeJSON(messages.jsonObject)
    }

    @NodeMethod func getThreads(folderName: String, pagination: NodeObject?) async throws -> String {
        let threads = try await api.getThreads(folderName: folderName, pagination: try paginationArg(from: pagination))
        return try encodeJSON(threads.jsonObject)
    }

    @NodeMethod func getMessages(threadID: String, pagination: NodeObject?) async throws -> String {
        let messages = try await api.getMessages(threadID: threadID, pagination: try paginationArg(from: pagination))
        return try encodeJSON(messages.jsonObject)
    }

    @NodeMethod func getThread(threadID: String) async throws -> String {
        let thread = try await api.getThread(threadID: threadID)
        return try encodeJSON(thread?.jsonObject)
    }

    @NodeMethod func getMessage(threadID: String, messageID: String) async throws -> String {
        let message = try await api.getMessage(threadID: threadID, messageID: messageID)
        return try encodeJSON(message?.jsonObject)
    }

    @NodeMethod func getOriginalObject(objName: String, objectID: String) async throws -> String {
        try await api.getOriginalObject(objName: objName, objectID: objectID)
    }

    @NodeMethod func createThread(userIDs userIDsValue: NodeArray, title: String?, messageText: String?) async throws -> String {
        let userIDs = try userIDsValue.as([String].self).orThrow(ErrorMessage("Bad PlatformAPI call: \(#function)"))
        let result = try await api.createThread(userIDs: userIDs, title: title, messageText: messageText)
        return try encodeJSON(result.jsonValue)
    }

    @NodeMethod func updateThread(threadID: String, muted: Bool) async throws {
        try await api.updateThread(threadID: threadID, muted: muted)
    }

    @NodeMethod func deleteThread(threadID: String) async throws {
        try await api.deleteThread(threadID: threadID)
    }

    @NodeMethod func sendMessage(threadID: String, text: String?, filePath: String?, quotedMessageID: String?) async throws -> String {
        let result = try await api.sendMessage(threadID: threadID, text: text, filePath: filePath, quotedMessageID: quotedMessageID)
        return try encodeJSON(result.jsonValue)
    }

    @NodeMethod func sendFileFromBuffer(threadID: String, fileBuffer: Data, fileName: String?, quotedMessageID: String?) async throws -> String {
        let result = try await api.sendFileFromBuffer(threadID: threadID, fileBuffer: fileBuffer, fileName: fileName, quotedMessageID: quotedMessageID)
        return try encodeJSON(result.jsonValue)
    }

    @NodeMethod func editMessage(threadID: String, messageID: String, content: String?) async throws {
        try await api.editMessage(threadID: threadID, messageID: messageID, content: content)
    }

    @NodeMethod func sendActivityIndicator(type: String, threadID: String?) async throws {
        try await api.sendActivityIndicator(type: type, threadID: threadID)
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
              let sendEventsFunction = try args[1].as(NodeFunction.self)
        else {
            throw ErrorMessage("Bad PlatformAPI call: \(#function)")
        }

        let sendEvents = SendableBox(sendEventsFunction)
        let eventQueue = try NodeAsyncQueue(label: "watch-imessage-callback")
        try await api.onThreadSelected(threadID: threadID) { events in
            try eventQueue.run {
                _ = try sendEvents.value.dynamicallyCall(withArguments: [try NodeBridgeUtilities.nodeArray(from: events)])
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
        try removeCleanupHook()
    }

    private func removeCleanupHook() throws {
        guard let cleanupHook else {
            return
        }

        try NodeEnvironment.current.removeCleanupHook(cleanupHook)
        self.cleanupHook = nil
    }

    private func paginationArg(from object: NodeObject?) throws -> PlatformSDK.PaginationArg? {
        guard let object else { return nil }
        guard let cursor = try object["cursor"].as(String.self) else {
            throw ErrorMessage("Bad PlatformAPI call: pagination.cursor must be a string")
        }
        guard let directionValue = try object["direction"].as(String.self),
              let direction = PlatformSDK.PaginationDirection(rawValue: directionValue)
        else {
            throw ErrorMessage("Bad PlatformAPI call: pagination.direction must be 'after' or 'before'")
        }
        return PlatformSDK.PaginationArg(cursor: cursor, direction: direction)
    }
}
