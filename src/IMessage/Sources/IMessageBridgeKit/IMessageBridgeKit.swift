import Darwin
import Foundation
import IMessage
import IMessageCore
import PlatformSDK

private let defaultAccountID = "default"

private final class BridgeRuntime: @unchecked Sendable {
    static let shared = BridgeRuntime()

    private let lock = NSLock()
    private var api: PlatformAPI?
    private var didBootstrap = false

    private let eventCondition = NSCondition()
    private var eventBatches: [Any] = []
    private var eventsStarted = false

    func initialize(dataDirPath: String, verbose: Bool, useSecondaryInstance: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        if !didBootstrap {
            IMessageHost.bootstrapWithOptions(
                dataDirPath: dataDirPath,
                verbose: verbose,
                useSecondaryInstance: useSecondaryInstance
            )
            didBootstrap = true
        }

        if api == nil {
            api = try PlatformAPI(accountID: defaultAccountID)
        }
    }

    func platformAPI() throws -> PlatformAPI {
        lock.lock()
        defer { lock.unlock() }

        if let api {
            return api
        }
        let api = try PlatformAPI(accountID: defaultAccountID)
        self.api = api
        return api
    }

    func dispose() async throws {
        let currentAPI = takeAPIForDispose()
        try await currentAPI?.dispose()
        resetEventQueue()
    }

    private func takeAPIForDispose() -> PlatformAPI? {
        lock.lock()
        defer { lock.unlock() }
        let currentAPI = api
        api = nil
        eventsStarted = false
        return currentAPI
    }

    private func resetEventQueue() {
        eventCondition.lock()
        eventBatches.removeAll()
        eventCondition.broadcast()
        eventCondition.unlock()
    }

    func startEvents() async throws {
        let api = try platformAPI()

        guard markEventsStarted() else { return }

        api.subscribeToEvents { [weak self] events in
            let values = events.map { $0.jsonObject() }
            self?.appendEventBatch(values)
        }
        try await api.startEventWatchingFromCurrentState()
    }

    func watchChat(threadID: String) async throws {
        let api = try platformAPI()
        try await api.onThreadSelected(threadID: threadID) { [weak self] events in
            let values = events.map { $0.jsonObject() }
            self?.appendEventBatch(values)
        }
    }

    private func markEventsStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldStart = !eventsStarted
        eventsStarted = true
        return shouldStart
    }

    private func appendEventBatch(_ events: [Any]) {
        eventCondition.lock()
        eventBatches.append(events)
        eventCondition.signal()
        eventCondition.unlock()
    }

    func nextEventBatch(timeoutMilliseconds: Int) -> Any? {
        eventCondition.lock()
        defer { eventCondition.unlock() }

        if eventBatches.isEmpty, timeoutMilliseconds > 0 {
            let deadline = Date(timeIntervalSinceNow: Double(timeoutMilliseconds) / 1000.0)
            while eventBatches.isEmpty, eventCondition.wait(until: deadline) {}
        }

        guard !eventBatches.isEmpty else {
            return nil
        }
        return eventBatches.removeFirst()
    }
}

private struct PaginationInput: Decodable {
    let cursor: String
    let direction: String
}

private func parsePagination(_ raw: UnsafePointer<CChar>?) throws -> PlatformSDK.PaginationArg? {
    guard let raw else {
        return nil
    }
    let string = String(cString: raw)
    guard !string.isEmpty else {
        return nil
    }
    let data = Data(string.utf8)
    let decoded = try JSONDecoder().decode(PaginationInput.self, from: data)
    guard let direction = PlatformSDK.PaginationDirection(rawValue: decoded.direction) else {
        throw ErrorMessage("invalid pagination direction \(decoded.direction)")
    }
    return PlatformSDK.PaginationArg(cursor: decoded.cursor, direction: direction)
}

private func parseStringArray(_ raw: UnsafePointer<CChar>) throws -> [String] {
    let string = String(cString: raw)
    let data = Data(string.utf8)
    guard let values = try JSONSerialization.jsonObject(with: data) as? [String] else {
        throw ErrorMessage("expected JSON string array")
    }
    return values
}

private func assetResponse(_ result: PlatformAPI.AssetResult) -> Any {
    switch result {
    case let .url(url):
        return ["url": url]
    case let .data(data):
        return ["dataBase64": data.base64EncodedString()]
    }
}

private func jsonValue(_ raw: String) -> Any {
    guard let data = raw.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
        return raw
    }
    return value
}

private func response(ok value: Any?) -> UnsafeMutablePointer<CChar>? {
    let object: [String: Any] = [
        "ok": true,
        "payload": value ?? NSNull(),
    ]
    return cString(try? encodeJSON(object))
}

private func response(error: Error) -> UnsafeMutablePointer<CChar>? {
    let object: [String: Any] = [
        "ok": false,
        "error": String(describing: error),
    ]
    return cString(try? encodeJSON(object))
}

private func cString(_ string: String?) -> UnsafeMutablePointer<CChar>? {
    strdup(string ?? #"{"ok":false,"error":"failed to encode response"}"#)
}

private func runBlocking(_ operation: @escaping () async throws -> Any?) -> UnsafeMutablePointer<CChar>? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Protected<Result<Any?, Error>?>(nil)

    Task {
        do {
            let value = try await operation()
            box.withLock { $0 = .success(value) }
        } catch {
            box.withLock { $0 = .failure(error) }
        }
        semaphore.signal()
    }

    semaphore.wait()
    switch box.read() {
    case let .success(value):
        return response(ok: value)
    case let .failure(error):
        return response(error: error)
    case nil:
        return response(error: ErrorMessage("operation ended without a result"))
    }
}

@_cdecl("imessage_bridge_free")
public func imessage_bridge_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

@_cdecl("imessage_bridge_init")
public func imessage_bridge_init(
    _ dataDir: UnsafePointer<CChar>?,
    _ verbose: Int32,
    _ useSecondaryInstance: Int32
) -> UnsafeMutablePointer<CChar>? {
    do {
        let dataDirPath = dataDir.map(String.init(cString:)) ?? NSTemporaryDirectory()
        try BridgeRuntime.shared.initialize(
            dataDirPath: dataDirPath,
            verbose: verbose != 0,
            useSecondaryInstance: useSecondaryInstance != 0
        )
        return response(ok: ["accountID": defaultAccountID])
    } catch {
        return response(error: error)
    }
}

@_cdecl("imessage_bridge_dispose")
public func imessage_bridge_dispose() -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.dispose()
        return true
    }
}

@_cdecl("imessage_bridge_current_user")
public func imessage_bridge_current_user() -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().getCurrentUser().jsonObject
    }
}

@_cdecl("imessage_bridge_chats")
public func imessage_bridge_chats(_ paginationJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let pagination = try parsePagination(paginationJSON)
        let page = try await BridgeRuntime.shared.platformAPI().getThreads(folderName: "normal", pagination: pagination)
        return page.jsonObject
    }
}

@_cdecl("imessage_bridge_chat")
public func imessage_bridge_chat(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let threadID = String(cString: threadID)
        return try await BridgeRuntime.shared.platformAPI().getThread(threadID: threadID)?.jsonObject
    }
}

@_cdecl("imessage_bridge_messages")
public func imessage_bridge_messages(
    _ threadID: UnsafePointer<CChar>,
    _ paginationJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let threadID = String(cString: threadID)
        let pagination = try parsePagination(paginationJSON)
        return try await BridgeRuntime.shared.platformAPI().getMessages(threadID: threadID, pagination: pagination).jsonObject
    }
}

@_cdecl("imessage_bridge_send_text")
public func imessage_bridge_send_text(
    _ threadID: UnsafePointer<CChar>,
    _ text: UnsafePointer<CChar>,
    _ quotedMessageID: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let quoted = quotedMessageID.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        let result = try await BridgeRuntime.shared.platformAPI().sendMessage(
            threadID: String(cString: threadID),
            text: String(cString: text),
            filePath: nil,
            quotedMessageID: quoted
        )
        return result.jsonValue
    }
}

@_cdecl("imessage_bridge_send_file")
public func imessage_bridge_send_file(
    _ threadID: UnsafePointer<CChar>,
    _ filePath: UnsafePointer<CChar>,
    _ quotedMessageID: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let quoted = quotedMessageID.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        let result = try await BridgeRuntime.shared.platformAPI().sendMessage(
            threadID: String(cString: threadID),
            text: nil,
            filePath: String(cString: filePath),
            quotedMessageID: quoted
        )
        return result.jsonValue
    }
}

@_cdecl("imessage_bridge_create_chat")
public func imessage_bridge_create_chat(
    _ recipientsJSON: UnsafePointer<CChar>,
    _ messageText: UnsafePointer<CChar>,
    _ title: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let title = title.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        let result = try await BridgeRuntime.shared.platformAPI().createThread(
            userIDs: try parseStringArray(recipientsJSON),
            title: title,
            messageText: String(cString: messageText)
        )
        return result.jsonValue
    }
}

@_cdecl("imessage_bridge_edit")
public func imessage_bridge_edit(
    _ threadID: UnsafePointer<CChar>,
    _ messageID: UnsafePointer<CChar>,
    _ text: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().editMessage(
            threadID: String(cString: threadID),
            messageID: String(cString: messageID),
            content: String(cString: text)
        )
        return true
    }
}

@_cdecl("imessage_bridge_delete_message")
public func imessage_bridge_delete_message(
    _ threadID: UnsafePointer<CChar>,
    _ messageID: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().deleteMessage(
            threadID: String(cString: threadID),
            messageID: String(cString: messageID)
        )
        return true
    }
}

@_cdecl("imessage_bridge_react")
public func imessage_bridge_react(
    _ threadID: UnsafePointer<CChar>,
    _ messageID: UnsafePointer<CChar>,
    _ reactionKey: UnsafePointer<CChar>,
    _ enabled: Int32
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let api = try BridgeRuntime.shared.platformAPI()
        if enabled != 0 {
            try await api.addReaction(
                threadID: String(cString: threadID),
                messageID: String(cString: messageID),
                reactionKey: String(cString: reactionKey)
            )
        } else {
            try await api.removeReaction(
                threadID: String(cString: threadID),
                messageID: String(cString: messageID),
                reactionKey: String(cString: reactionKey)
            )
        }
        return true
    }
}

@_cdecl("imessage_bridge_mark_read")
public func imessage_bridge_mark_read(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().sendReadReceipt(threadID: String(cString: threadID))
        return true
    }
}

@_cdecl("imessage_bridge_mark_unread")
public func imessage_bridge_mark_unread(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().markAsUnread(threadID: String(cString: threadID))
        return true
    }
}

@_cdecl("imessage_bridge_mute")
public func imessage_bridge_mute(
    _ threadID: UnsafePointer<CChar>,
    _ muted: Int32
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().updateThread(
            threadID: String(cString: threadID),
            muted: muted != 0
        )
        return true
    }
}

@_cdecl("imessage_bridge_delete_chat")
public func imessage_bridge_delete_chat(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().deleteThread(threadID: String(cString: threadID))
        return true
    }
}

@_cdecl("imessage_bridge_notify_anyway")
public func imessage_bridge_notify_anyway(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().notifyAnyway(threadID: String(cString: threadID))
        return true
    }
}

@_cdecl("imessage_bridge_typing")
public func imessage_bridge_typing(
    _ threadID: UnsafePointer<CChar>,
    _ enabled: Int32
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().sendActivityIndicator(
            type: enabled != 0 ? "typing" : "none",
            threadID: String(cString: threadID)
        )
        return true
    }
}

@_cdecl("imessage_bridge_watch_chat")
public func imessage_bridge_watch_chat(_ threadID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.watchChat(threadID: String(cString: threadID))
        return true
    }
}

@_cdecl("imessage_bridge_search_messages")
public func imessage_bridge_search_messages(
    _ query: UnsafePointer<CChar>,
    _ threadID: UnsafePointer<CChar>?,
    _ paginationJSON: UnsafePointer<CChar>?,
    _ limit: Int32
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let thread = threadID.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        let pagination = try parsePagination(paginationJSON)
        let page = try await BridgeRuntime.shared.platformAPI().searchMessages(
            typed: String(cString: query),
            threadID: thread,
            mediaOnly: nil,
            sender: nil,
            pagination: pagination,
            limit: limit > 0 ? Int(limit) : nil
        )
        return page.jsonObject
    }
}

@_cdecl("imessage_bridge_get_asset")
public func imessage_bridge_get_asset(
    _ pathHex: UnsafePointer<CChar>,
    _ methodName: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        let method = methodName.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
        let result = try await BridgeRuntime.shared.platformAPI().getAsset(
            pathHex: String(cString: pathHex),
            methodName: method
        )
        return assetResponse(result)
    }
}

@_cdecl("imessage_bridge_load_attachment")
public func imessage_bridge_load_attachment(_ messageID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.platformAPI().loadAttachment(messageID: String(cString: messageID))
        return true
    }
}

@_cdecl("imessage_bridge_start_events")
public func imessage_bridge_start_events() -> UnsafeMutablePointer<CChar>? {
    runBlocking {
        try await BridgeRuntime.shared.startEvents()
        return true
    }
}

@_cdecl("imessage_bridge_next_events")
public func imessage_bridge_next_events(_ timeoutMilliseconds: Int32) -> UnsafeMutablePointer<CChar>? {
    let events = BridgeRuntime.shared.nextEventBatch(timeoutMilliseconds: Int(timeoutMilliseconds))
    return response(ok: events)
}
