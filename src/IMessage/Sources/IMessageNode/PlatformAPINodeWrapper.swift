import Foundation
import NodeAPI
import IMessage
import IMessageCore

@NodeActor @NodeClass final class PlatformAPINodeWrapper {
    private let api: PlatformAPI

    @NodeConstructor init(accountID: String) {
        api = PlatformAPI(accountID: accountID, runtime: PlatformAPINodeRuntime.makeRuntime())
    }

    @NodeMethod func getCurrentUser() async throws -> String {
        let currentUser = try await api.getCurrentUser()
        return try encodeJSON(currentUser.jsonObject)
    }

    @NodeMethod func searchMessages(typed: String, threadID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) async throws -> String {
        let messages = try await api.searchMessages(typed: typed, threadID: threadID, mediaOnly: mediaOnly, sender: sender, limit: limit)
        return try encodeJSON(messages.jsonObject)
    }

    @NodeMethod func getThreads(folderName: String, cursor: String?, direction: String?) async throws -> String {
        let threads = try await api.getThreads(folderName: folderName, cursor: cursor, direction: direction)
        return try encodeJSON(threads.jsonObject)
    }

    @NodeMethod func getMessages(threadID: String, cursor: String?, direction: String?, limit: Int?) async throws -> String {
        let messages = try await api.getMessages(threadID: threadID, cursor: cursor, direction: direction, limit: limit)
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
              let sendEventsFunction = try args[1].as(NodeFunction.self)
        else {
            throw ErrorMessage("Bad PlatformAPI call: \(#function)")
        }

        let sendEvents = SendableBox(sendEventsFunction)
        try await api.onThreadSelected(threadID: threadID) { events in
            try NodeActor.unsafeAssumeIsolated {
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
    }
}
