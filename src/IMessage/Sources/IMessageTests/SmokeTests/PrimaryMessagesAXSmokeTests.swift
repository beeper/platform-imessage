import AppKit
import ApplicationServices
import AccessibilityControl
import Testing
import IMessageCore
@testable import IMessage

// Opt-in only: temporarily coordinates the real primary, without sending messages.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_PRIMARY_AX_SMOKE"] == "1"))
@MainActor
func primaryMessagesAXSmoke() throws {
    try #require(AXIsProcessTrusted(), "Primary AX smoke requires Accessibility permission")
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let app = try #require(apps.count == 1 ? apps.first : nil, "Requires exactly one primary Messages instance")
    try #require(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    Defaults.registerDefaults()
    let wasHidden = app.isHidden
    let elements = MessagesAppElements(runningApp: app)
    let window = try elements.mainWindow
    let originalFrame = try window.frame()
    let coordinator = EclipsingWindowCoordinator()
    coordinator.app = app
    defer {
        try? coordinator.restoreDockPresence()
        try? window.setFrame(originalFrame)
        if wasHidden { app.hide() } else { app.unhide() }
    }
    let observer = LifecycleObserver()
    let ready = DispatchSemaphore(value: 0)
    let observationError = Protected<Error?>()
    let thread = RunLoopConveyor<Void>(oneTimeInitialization: { _ in
        do {
            try observer.beginObserving(app: elements.app)
            try observer.beginObserving(window: window)
        } catch {
            observationError.withLock { $0 = error }
        }
        ready.signal()
    }, handlingWorkItemsWithinRunLoop: { _ in })
    thread.start()
    defer { thread.cancel() }
    try #require(ready.wait(timeout: .now() + 5) == .success)
    if let error = observationError.read() { throw error }
    let chatURLs = try primarySmokeReadChatURLs()
    let repeatedChat = try #require(chatURLs.last)
    let compose = try #require(URL(string: "imessage:open?address=&body"))
    for stage in ["foreground", "restored"] {
        try coordinator.restoreDockPresence()
        app.unhide()
        for (trial, url) in ([compose] + chatURLs + [repeatedChat]).enumerated() {
            let before = Date()
            let waitStarted = try primarySmokeOpenDeepLink(url, app: app)
            pumpSmokeRunLoop(for: 1.2)
            let actualType = try MessagesDockSuppression.applicationType(for: app.processIdentifier)
            #expect(actualType == "Foreground")
            let focus = observer.lastFocusedUIElementChange.read()
            let layout = observer.lastLayoutChange.read()
            print("PRIMARY_AX stage=\(stage) trial=\(trial) focusAfterLink=\(focus.map { $0 > before } ?? false) focusWaiter=\(focus.map { $0 > waitStarted } ?? false) layoutWaiter=\(layout.map { $0 > waitStarted } ?? false)")
            #expect(focus.map { $0 > waitStarted } ?? false, "Focus waiter failed at \(stage) trial \(trial)")
            if trial > 0 {
                let field = try elements.messageBodyField
                try field.isFocused(assign: true)
                let setFocused = try field.isFocused()
                try field.press()
                let pressFocused = try field.isFocused()
                print("PRIMARY_BODY stage=\(stage) trial=\(trial) setFocused=\(setFocused) pressFocused=\(pressFocused)")
                #expect(setFocused || pressFocused, "Body focus failed at \(stage) trial \(trial)")
            }
        }
    }
    #expect(!app.isTerminated)
}

// Select only conversations with no unread incoming messages. Never log identifiers.
private func primarySmokeReadChatURLs() throws -> [URL] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        "-readonly", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path,
        "SELECT c.guid FROM chat c WHERE c.guid LIKE '%;-;%' AND EXISTS (SELECT 1 FROM chat_message_join j WHERE j.chat_id=c.ROWID) AND NOT EXISTS (SELECT 1 FROM chat_message_join j JOIN message m ON m.ROWID=j.message_id WHERE j.chat_id=c.ROWID AND m.is_from_me=0 AND m.is_read=0) ORDER BY c.ROWID DESC LIMIT 2;",
    ]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "Read-only chat selection requires Messages data access")
    let ids = try #require(String(data: data, encoding: .utf8)).split(separator: "\n")
    let requiredChats = 2
    try #require(ids.count == requiredChats, "Requires two existing conversations with no unread incoming messages")
    return try ids.map { try MessagesDeepLink(threadID: String($0), body: nil).url() }
}

@MainActor
private func primarySmokeOpenDeepLink(_ url: URL, app: NSRunningApplication) throws -> Date {
    let (target, started) = try runSmokeWorker {
        let target = try MessagesController.openDeepLink(url, targeting: app)
        return (target, Date())
    }
    try #require(target.processIdentifier == app.processIdentifier, "Deep link targeted a different Messages instance")
    return started
}
