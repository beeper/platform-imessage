import AppKit
import Contacts
import Carbon.HIToolbox.Events
import AccessibilityControl
import WindowControl

private final class TimerBlockWatcher {
    let block: () -> Void
    init(_ block: @escaping () -> Void) {
        self.block = block
    }
    @objc func timerFired() {
        block()
    }
}

private final class RunLoopThread: Thread {
    private var initialize: (() -> Void)?
    // safe to retain self inside initialize because it's nil'd out
    // once main() is called
    init(initialize: @escaping () -> Void) {
        self.initialize = initialize
    }
    override func main() {
        initialize?()
        initialize = nil
        while !isCancelled {
            // we need to set a finite deadline, otherwise once the source
            // is removed we'll be stuck here and never get to the next
            // isCancelled check
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
        }
    }
}

let messagesBundleID = "com.apple.MobileSMS"
let isMontereyOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0))
let isVenturaOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))

enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!

    static let imessage = chatKitFramework.localizedString(forKey: "MADRID", value: nil, table: "ChatKit")
    static let textMessage = chatKitFramework.localizedString(forKey: "TEXT_MESSAGE", value: nil, table: "ChatKit")

    static let markAsRead = chatKitFramework.localizedString(forKey: "MARK_AS_READ", value: nil, table: "ChatKit")
    static let markAsUnread = chatKitFramework.localizedString(forKey: "MARK_AS_UNREAD", value: nil, table: "ChatKit")
    static let delete = chatKitFramework.localizedString(forKey: "DELETE", value: nil, table: "ChatKit")
    static let pin = chatKitFramework.localizedString(forKey: "PIN", value: nil, table: "ChatKit")
    static let unpin = chatKitFramework.localizedString(forKey: "UNPIN", value: nil, table: "ChatKit")

    static let hasNotificationsSilencedSuffix = chatKitFramework.localizedString(forKey: "UNAVAILABILITY_INDICATOR_TITLE_FORMAT", value: nil, table: "ChatKit").replacingOccurrences(of: "%@", with: "")
    static let notifyAnyway = chatKitFramework.localizedString(forKey: "NOTIFY_ANYWAY_BUTTON_TITLE", value: nil, table: "ChatKit")

    static let replyTranscript = chatKitFrameworkAxBundle.localizedString(forKey: "group.reply.collection", value: nil, table: "Accessibility")

    static let showAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "show.alerts.collection.view.cell", value: nil, table: "Accessibility")
    static let hideAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "hide.alerts.collection.view.cell", value: nil, table: "Accessibility")

    static let react = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgments.action.title", value: nil, table: "Accessibility")
    static let reply = chatKitFrameworkAxBundle.localizedString(forKey: "balloon.message.reply", value: nil, table: "Accessibility")
}

private enum MessageAction {
    case react, reply

    var localized: String {
        switch self {
            case .react: return LocalizedStrings.react
            case .reply: return LocalizedStrings.reply
        }
    }
}
private enum ThreadAction {
    case markAsRead, markAsUnread, delete, pin, unpin, showAlerts, hideAlerts

    var localized: String {
        switch self {
            case .markAsRead: return LocalizedStrings.markAsRead
            case .markAsUnread: return LocalizedStrings.markAsUnread
            case .delete: return LocalizedStrings.delete
            case .pin: return LocalizedStrings.pin
            case .unpin: return LocalizedStrings.unpin
            case .showAlerts: return LocalizedStrings.showAlerts
            case .hideAlerts: return LocalizedStrings.hideAlerts
        }
    }
}

struct MessageCell: Codable {
    let messageGUID: String
    let offset: Int
    let cellID: String?
    let cellRole: String?
    let overlay: Bool
}

// TODO: refactor
private class KeyPresser {
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }

    private func press(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        debugLog("sendKey(key: \(key))")
        for keyDown in [true, false] {
            debugLog("sendKey(key: \(key)) \(keyDown ? "down" : "up")")
            let ev = try CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            if let flags = flags { ev.flags = flags }
            ev.postToPid(self.pid)
        }
    }

    func `return`() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Return))
        }
    }

    func commandV() throws {
        try runOnMainThread {
            // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
            guard let keyCode = KeyMap.shared["v"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }

    /// marks as read/unread on ventura
    func commandShiftU() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["u"] else { return }
            try press(key: CGKeyCode(keyCode), flags: [.maskCommand, .maskShift])
        }
    }

    /// selects first thread
    func command1() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["1"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }

    /// selects prev thread, both keys aren't the same in practice
    func commandLeftBracket() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["["] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    func ctrlShiftTab() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift])
        }
    }

    /// selects next thread, both keys aren't the same in practice
    func commandRightBracket() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["]"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    func ctrlTab() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Tab), flags: .maskControl)
        }
    }

    /// selects first non-pinned thread
    func commandOption1() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["1"] else { return }
            try press(key: CGKeyCode(keyCode), flags: [.maskCommand, .maskAlternate])
        }
    }
}

// external API is thread safe
final class MessagesController {
    enum Reaction: String {
        case heart
        case like
        case dislike
        case laugh
        case emphasize
        case question

        var index: Int {
            switch self {
            case .heart: return 0
            case .like: return 1
            case .dislike: return 2
            case .laugh: return 3
            case .emphasize: return 4
            case .question: return 5
            }
        }
    }

    enum ActivityStatus: String {
        case dnd = "DND"
        case dndCanNotify = "DND_CAN_NOTIFY"
        case typing = "TYPING"
        case notTyping = "NOT_TYPING"
        case unknown = "UNKNOWN"
    }

    private class ActivityObserver {
        let threadID: String
        let url: URL

        // may be called on a bg thread
        private let callback: ([ActivityStatus]) -> Void

        private var lastSent: [ActivityStatus] = [.notTyping]
        private var lastSentTime = Date()

        init(threadID: String, url: URL, callback: @escaping ([ActivityStatus]) -> Void) {
            self.threadID = threadID
            self.url = url
            self.callback = callback
        }

        func send(_ status: [ActivityStatus]) {
            // send if the status is different OR if we're sending typing events and it's
            // been a long time since the last one
            guard lastSent != status || (status.contains(.typing) && lastSentTime.timeIntervalSinceNow > 30) else {
                return
            }
            lastSent = status
            lastSentTime = Date()
            callback(status)
        }
    }

    private static let pollingInterval: TimeInterval = 1

    private let app: NSRunningApplication
    private let elements: MessagesAppElements

    private var timer: Timer?
    private var loopThread: RunLoopThread?

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?
    #if DEBUG
    private var layoutChangedToken: Accessibility.Observer.Token?
    #endif

    private var activityObserver: ActivityObserver?

    private let whm: WindowHidingManager
    private let keyPresser: KeyPresser
    private let contacts = Contacts()

    // this increases the viewport height so that mark as read works more reliably
    static func resizeWindowToMaxHeight(_ window: Accessibility.Element) throws {
        var frame = try window.frame()
        frame.origin.y = 0
        frame.size.height = Double.infinity
        try window.setFrame(frame)
    }

    // without expanding splitter, thread cells will not have custom ax actions (on monterey at least)
    func expandSplitter() throws {
        if try elements.conversationsList.size().width < 99 { // width is 94 when in compact mode
            try elements.splitter.increment()
        }
    }

    private static func terminateApp(_ app: NSRunningApplication) throws {
        app.terminate()
        try retry(withTimeout: 2, interval: 0.1) {
            guard app.isTerminated else { throw ErrorMessage("App couldn't be terminated") }
        } onError: { attempt, _ in
            if attempt == 19 {
                debugLog("Force terminating app")
                app.forceTerminate()
            }
        }
    }

    @discardableResult
    static func openDeepLink(_ url: URL, withoutActivation: Bool = true) throws -> NSRunningApplication {
        debugLog("openDeepLink: \(url)")
        return try NSWorkspace.shared.open(
            url,
            options: withoutActivation ? [.andHide, .withoutActivation] : [.andHide],
            configuration: [:]
        )
    }

    private func isSameContact(_ a: String?, _ b: String?) -> Bool {
        guard let contacts = contacts, let a = a, let b = b else { return false }
        return contacts.fetchID(for: a) == contacts.fetchID(for: b)
    }

    // ignores the service (SMS or iMessage) and matches contact identifiers since it's merged in the UI
    private func ensureSelectedThread(threadID: String) throws {
        let (_, type, addressToMatch) = try splitThreadID(threadID).orThrow(ErrorMessage("invalid threadID"))
        try retry(withTimeout: 1.2, interval: 0.05) {
            let selectedAddress = try Defaults.getSelectedThreadID().flatMap(threadIDToAddress).orThrow(ErrorMessage("unknown thread selected"))
            guard selectedAddress == addressToMatch ||
                (type == singleThreadType && isSameContact(selectedAddress, addressToMatch))
            else { throw ErrorMessage("thread not selected") }
        }
    }

    private func openThread(_ threadID: String) throws {
        try Self.openDeepLink(try MessagesDeepLink(threadID: threadID, body: nil).url())
        try ensureSelectedThread(threadID: threadID)
    }

    private static func getRunningMessagesApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    }

    init() throws {
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Texts does not have Accessibility permissions")
        }

        whm = try getBestWHM()

        let launchMessages = { [whm] (withoutActivation: Bool) throws -> NSRunningApplication in
            if !whm.canReuseApp { Thread.sleep(forTimeInterval: 0.1) } // waiting reduces the likelihood that messages.app shows up visible (requiring us to restart it)
            debugLog("Launching Messages...")
            return try Self.openDeepLink(MessagesDeepLink.compose.url(), withoutActivation: withoutActivation)
        }

        var messagesApps = Self.getRunningMessagesApps()
        if messagesApps.count > 1 { // if there's more than one instance of messages app something weird happened, terminate all to be safe
            debugLog("\(messagesApps.count) messages.app instances, terminating all")
            messagesApps.forEach { try? Self.terminateApp($0) }
            messagesApps.removeAll()
        }
        if let existingApp = messagesApps.first {
            if whm.canReuseApp {
                debugLog("Reusing existing Messages...")
                app = existingApp
            } else {
                debugLog("Terminating Messages...")
                try Self.terminateApp(existingApp)
                // this is for markAsReadWithPressHack (monterey or lower)
                // launch with activation because the hack doesn't work until the app is activated at least once
                app = try launchMessages(!isVenturaOrUp)
            }
        } else {
            app = try launchMessages(false)
        }

        // without sleeping, appElement.observe applicationActivated/applicationDeactivated doesn't fire
        try app.waitForLaunch()
        elements = MessagesAppElements(runningApp: app, whm: whm)
        keyPresser = KeyPresser(pid: app.processIdentifier)
        whm.setApp(app)
        whm.setAfterHide {
            self.elements.getMainWindow().map { try? Self.resizeWindowToMaxHeight($0) }
        }

        // if app.isHidden {
        //     debugLog("Unhiding Messages...")
        //     try retry(withTimeout: 1, interval: 0.1) { [app] in
        //         app.unhide()
        //         if app.isHidden {
        //             throw ErrorMessage("Could not launch Messages")
        //         }
        //     }
        // }

        // we need a run loop for polling (and for any future AX observers), but Node
        // doesn't offer us one (since it uses its own uv loop which is incompatible
        // with NS/CFRunLoop). Therefore we create a background thread with a run loop.
        // Note that doing so on a dispatch queue would be very inefficient and so we
        // create our own thread for it; see https://stackoverflow.com/a/38001438/3769927 and
        // https://forums.swift.org/t/runloop-main-or-dispatchqueue-main-when-using-combine-scheduler/26635/4

        // we use a timer instead of observe(.layoutChanged) here because AX doesn't emit the event when the window is hidden
        let thread = RunLoopThread {
            let watcher = TimerBlockWatcher { [weak self] in
                self?.pollActivityStatus()
            }
            self.timer = Timer.scheduledTimer(
                timeInterval: Self.pollingInterval,
                target: watcher,
                selector: #selector(TimerBlockWatcher.timerFired),
                userInfo: nil,
                repeats: true
            )
            self.activateToken = try? self.elements.app.observe(.applicationActivated) { [weak self] _ in
                self?.activateMessages()
            }
            self.deactivateToken = try? self.elements.app.observe(.applicationDeactivated) { [weak self] _ in
                self?.deactivateMessages()
            }
            #if DEBUG
            self.layoutChangedToken = try? self.elements.app.observe(.layoutChanged) { _ in // [weak self] _ in
                debugLog("layoutChanged")
                // self?.pollActivityStatus()
            }
            #endif
        }
        thread.qualityOfService = .utility
        thread.start()
        self.loopThread = thread

        guard isValid else {
            dispose() // since deinit isn't called when init throws
            throw ErrorMessage("Initialized MessagesController in an invalid state: appTerminated=\(app.isTerminated), mwFrameValid=\(Result { try elements.mainWindow.isFrameValid }), whmValid=\(whm.isValid)")
        }
        try? expandSplitter()
    }

    var isValid: Bool {
        !app.isTerminated && (try? elements.mainWindow.isFrameValid) != nil && whm.isValid
    }

    private func messageAction(messageCell: Accessibility.Element, action: MessageAction) throws -> Accessibility.Action {
        // [press, AXScrollToVisible, show menu, Escape, scroll left by a page, scroll right by a page, React, Reply, Copy]
        // ["AXPress", "AXScrollToVisible", "AXShowMenu", "AXCancel", "AXScrollLeftByPage", "AXScrollRightByPage", "Name:React\nTarget:0x0\nSelector:(null)", "Name:Reply\nTarget:0x0\nSelector:(null)", "Name:Copy\nTarget:0x0\nSelector:(null)"]
        // non-AX actions are [React, Reply, Copy, Pin]
        // Pin is missing for non-links / Big Sur
        let allActions = try messageCell.supportedActions()
        let action = try allActions.first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") })
            .orThrow(ErrorMessage("MessageAction.\(action) not found"))
        return action
    }

    private func triggerThreadCellAction(threadCell: Accessibility.Element, action: ThreadAction) throws {
        let action = try threadCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") })
            .orThrow(ErrorMessage("ThreadAction.\(action) not found"))
        try action()
    }

    private func triggerThreadCellAction(threadID: String, action: ThreadAction) throws {
        let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
        try triggerThreadCellAction(threadCell: threadCell, action: action)
    }

    private func selectNextThreadAndScroll() throws {
        let threadID = Defaults.getSelectedThreadID()
        // ctrlTab() acts differently, has no effect?
        try keyPresser.commandRightBracket() // scrolls to next thread cell, rare edge case: won't work for the last item
        try retry(withTimeout: 0.5, interval: 0.05) { // wait for hotkey to switch threads
            guard Defaults.getSelectedThreadID() != threadID else { throw ErrorMessage("diff thread not selected") }
        }
    }

    /*
        other approaches tried here:
        #1:
            1. select not-in-viewport thread by opening deep link
            2. close all windows
            3. open deep link, thread will be in viewport but only when `.withoutActivation` isn't included in options
            ofc can't use bc can't activate app

        #2:
            try elements.selectedThreadCell?.scrollToVisible()
            only works for thread cells that are slightly offscreen/fully visible and for thread cells whose reference was taken _when_ they were in viewport
            elements.selectedThreadCell is an invalid reference if selected cell is offscreen

        #3
            1. keyPresser.command1
            2. open and get compose cell
            3. open target thread
            4. triggerThreadCellAction(threadCell: composeCell, action: .delete) // scrolls to wanted thread
    */
    private func scrollAndGetSelectedThreadCell(threadID: String) throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("scrollAndGetSelectedThreadCell took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        // we assume thread is already selected

        let selectedCell = try elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCell.isInViewport { return selectedCell }

        try selectNextThreadAndScroll()
        try openThread(threadID)

        let selectedCellAfterScroll = try elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCellAfterScroll.isInViewport { return selectedCellAfterScroll }
        throw ErrorMessage("threadCell not found")
    }

    // performs `perform` while the Messages window is unhidden
    private func withActivation(
        openBefore: URL?, openAfter: URL?,
        perform: () throws -> Void
    ) throws {
        if let openBefore = openBefore {
            try Self.openDeepLink(openBefore)
        }

        try perform()

        if let openAfter = openAfter {
            if openAfter == openBefore {
                // debugLog("withActivation: skipping, openAfter == openBefore")
            } else {
                // debugLog("withActivation: returning to openAfter \(openAfter)")
                try Self.openDeepLink(openAfter)
            }
        }
    }

    private func withMessageCell(threadID: String, messageCell: MessageCell, action: (_ cell: Accessibility.Element) throws -> Void) throws {
        debugLog("withMessageCell \(messageCell)")

        let url = try MessagesDeepLink.message(guid: messageCell.messageGUID, overlay: messageCell.overlay).url()

        // without closing reply transcript, non-overlay deep link won't select the message
        if !messageCell.overlay, let rtv = try? elements.replyTranscriptView {
            debugLog("calling replyTranscriptView.cancel()")
            try? rtv.cancel()
        }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)

            // we don't close transcript view here because when reacting, closing it will undo the reaction
            // defer {
            //     if messageCell.overlay {
            //         // alt: try? sendKeyPress(key: CGKeyCode(kVK_Escape))
            //         Thread.sleep(forTimeInterval: 0.1)
            //         try? elements.replyTranscriptView.cancel()
            //     }
            // }
            if messageCell.overlay { try waitUntilReplyTranscriptVisible() }
            guard let selected = (try retry(withTimeout: 1, interval: 0.2) { () -> Accessibility.Element? in
                guard let cell = try messageCell.overlay ? MessagesAppElements.firstMessageCell(in: elements.replyTranscriptView) : MessagesAppElements.firstSelectedMessageCell(in: elements.transcriptView) else {
                    throw ErrorMessage("message cell nil")
                }
                guard cell.isInViewport else { throw ErrorMessage("message cell not in viewport") }
                return cell
            }) else {
                throw ErrorMessage("Could not find message cell")
            }
            let targetCell: Accessibility.Element
            if messageCell.offset == 0 {
                targetCell = selected
            } else {
                let containerCell = try selected.parent()
                let containerFrame = try containerCell.frame()
                let containerCells = try MessagesAppElements.messageContainerCells(in: messageCell.overlay ? elements.replyTranscriptView : elements.transcriptView)
                guard let idx = containerCells.firstIndex(where: { (try? $0.frame()) == containerFrame }) else {
                    throw ErrorMessage("Could not find target message cell")
                }
                let target = idx - messageCell.offset
                debugLog("Index: \(idx) - \(messageCell.offset) = \(target)")
                guard containerCells.indices.contains(target) else {
                    throw ErrorMessage("Desired index out of bounds")
                }
                targetCell = try containerCells[target].children.value(at: 0)
            }
            if let cellRole = messageCell.cellRole, let role = try? targetCell.role() {
                guard role == cellRole else {
                    debugLog("Expected cell role \(cellRole), got \(role)")
                    throw ErrorMessage("Cell role mismatch")
                }
            }
            if let cellID = messageCell.cellID, let id = try? targetCell.identifier() {
                guard id == cellID else {
                    debugLog("Expected cell id \(cellID), got \(id)")
                    throw ErrorMessage("Cell id mismatch")
                }
            }
            try action(targetCell)
        }
    }

    func setReaction(threadID: String, messageCell: MessageCell, reaction: Reaction, on: Bool) throws {
        let startTime = Date()
        defer { Logger.log("setReaction took \(startTime.timeIntervalSinceNow * -1000)ms") }

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        let idx = reaction.index
        try withMessageCell(threadID: threadID, messageCell: messageCell) {
            let reactAction = try messageAction(messageCell: $0, action: .react)
            try reactAction() // performing this 2x will close reaction view
            let buttons = try elements.reactButtons
            guard buttons.count >= idx else {
                throw ErrorMessage("reactButtons count=\(buttons.count)")
            }

            let btn = buttons[idx]
            try retry(withTimeout: 1.2, interval: 0.1) {
                let isSelected = try btn.isSelected()
                if isSelected != on {
                    try btn.press()
                    debugLog("Reaction: \(Result { try btn.localizedDescription() }) \(Result { try btn.isSelected() })")
                    guard try btn.isSelected() == on else {
                        throw ErrorMessage("Could not react")
                    }
                }
            }
        }
    }

    #if DEBUG
    // this is unusable because showing menu makes it first responder
    // keep this code as documentation
    func markAsReadWithMenu(threadID: String, messageGUID: String) throws {
        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        let url = try MessagesDeepLink.message(guid: messageGUID, overlay: false).url()
        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)

            let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
            try threadCell.showMenu()

            guard let menu = (try retry(withTimeout: 2, interval: 0.1) { try elements.iOSContentGroup.children().first(where: { try $0.role() == AXRole.menu }) }) else {
                throw ErrorMessage("menu not found")
            }
            /*
             AXMenuItem unpin
             AXMenuItem open_conversation_in_separate_window
             AXMenuItem delete_conversation…
             AXMenuItem
             AXMenuItem details…
             AXMenuItem hide_alerts
             AXMenuItem mark_as_read
             AXMenuItem
             AXMenuItem
             */
            guard let markAsReadMenuItem = (try retry(withTimeout: 0.5, interval: 0.1) { try menu.children().first(where: { (try? $0.identifier()) == "mark_as_read" }) }) else {
                throw ErrorMessage("markAsReadMenuItem not found")
            }
            try markAsReadMenuItem.press()
        }
    }
    #endif

    // this only works when the messages.app window has been activated at least once
    // can randomly stop working. a reactivation of messages.app may fix (unhandled)
    private func markAsReadWithPressHack(threadID: String) throws {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("markAsReadWithPressHack took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        try openThread(threadID)
        let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
        // select any another cell and then come back
        try selectNextThreadAndScroll()
        // scrollToVisible is needed since sometimes the thread cell can be behind the search input field causing .press() to focus the input field instead
        try threadCell.scrollToVisible()
        try threadCell.press()
        try? ensureSelectedThread(threadID: threadID)
    }

    /*
        uses four methods:
        1. for ventura: hotkey                                                  (reliable)
        2. for pinned threads: mark-read action                                 (reliable)
        3. when less than 9 pinned threads: pin thread, #2, unpin               (reliable)
        4. threadCell.press() action hack                                       (unreliable)
    */
    func toggleThreadRead(threadID: String, messageGUID: String, read: Bool) throws {
        let startTime = Date()
        defer { Logger.log("toggleThreadRead took \(startTime.timeIntervalSinceNow * -1000)ms") }

        let url = try MessagesDeepLink.message(guid: messageGUID, overlay: false).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)
            if isVenturaOrUp {
                return try keyPresser.commandShiftU()
            }
            let action = read ? ThreadAction.markAsRead : ThreadAction.markAsUnread
            if Defaults.isSelectedThreadCellPinned() {
                try triggerThreadCellAction(threadID: threadID, action: action)
            } else if let count = Defaults.pinnedThreadsCount(), count < 9 {
                try triggerThreadCellAction(threadID: threadID, action: .pin)
                defer {
                    try? triggerThreadCellAction(threadID: threadID, action: .unpin)
                }
                // after pin/unpin elements.selectedThreadCell is nil because no cells are selected
                // openThread ensures scroll logic isn't executed
                try openThread(threadID)
                try triggerThreadCellAction(threadID: threadID, action: action)
            } else {
                try markAsReadWithPressHack(threadID: threadID)
            }
        }
    }

    func muteThread(threadID: String, muted: Bool) throws {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("muteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)
            // at least on Monterey: for pinned thread cells, this should be
            // Defaults.isSelectedThreadCellPinned() ? LocalizedStrings.hideAlerts : LocalizedStrings.hideAlerts + ", On"
            let action = muted || Defaults.isSelectedThreadCellPinned() ? ThreadAction.hideAlerts : ThreadAction.showAlerts
            try triggerThreadCellAction(threadID: threadID, action: action)
        }
    }

    func deleteThread(threadID: String) throws {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("deleteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)
            try triggerThreadCellAction(threadID: threadID, action: .delete)
            try elements.alertSheetDeleteButton.press()
        }
    }

    func sendTypingStatus(threadID: String, isTyping: Bool) throws {
        debugLog("sendTypingStatus threadID=\(threadID) isTyping=\(isTyping)")

        // a space is enough to send a typing indicator, while ensuring that
        // users can't accidentally hit return to send a single-char message
        // (since Messages special-cases space-only messages). The NUL byte
        // is another option that doesn't get sent to the server, but it
        // shows up client-side as a ghost message.
        let url = try MessagesDeepLink(threadID: threadID, body: isTyping ? " " : nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            if isTyping { return } // no further action required

            try ensureSelectedThread(threadID: threadID)

            try elements.messageBodyField.value(assign: "")
        }
    }

    private func focusMessageField(_ messageField: Accessibility.Element) {
        try? retry(withTimeout: 0.8, interval: 0.1) {
            // this doesn't ever focus in compose thread for some reason
            try messageField.isFocused(assign: true)
            if Defaults.isSelectedThreadCellCompose() { return }
            guard try messageField.isFocused() else {
                throw ErrorMessage("Could not focus message field")
            }
        }
    }

    private func messageFieldValue(_ messageField: Accessibility.Element) throws -> String? {
        if isVenturaOrUp {
            return (try messageField.value() as? NSAttributedString).flatMap { $0.string }
        }
        return try messageField.value() as? String
    }

    private func assignToMessageField(_ messageField: Accessibility.Element, text: String) throws {
        try retry(withTimeout: 1, interval: 0.2) {
            try messageField.value(assign: text)
            guard (try? messageFieldValue(messageField)) == text else {
                throw ErrorMessage("Could not assign value to message field")
            }
        }
    }

    private func sendMessageInField(_ messageField: Accessibility.Element) throws {
        focusMessageField(messageField) // focus is partially redundant, hitting enter without focus works too unless another text field is focused
        try keyPresser.return()
        try retry(withTimeout: 1.5, interval: 0.2) {
            if let message = try? messageFieldValue(messageField), !message.isEmpty {
                let hasNewline = message.hasSuffix("\n")
                throw ErrorMessage("Could not send message\(hasNewline ? " (extraneous newline)" : "")")
            }
        } onError: { attempt, _  in
            if attempt == 5 { // penultimate attempt
                // try? sendReturnPress()
            }
        }
    }

    private func closeReplyTranscriptView() throws {
        guard let rtv = try? elements.replyTranscriptView else { return }
        debugLog("calling replyTranscriptView.cancel()")
        try rtv.cancel()
        func waitForReplyTranscriptsClose() throws {
            try retry(withTimeout: 1.2, interval: 0.1) {
                guard let pValue = try? elements.messageBodyField.placeholderValue(),
                    pValue == LocalizedStrings.imessage || pValue == LocalizedStrings.textMessage else {
                    throw ErrorMessage("replyTranscriptView visible")
                }
            }
            Thread.sleep(forTimeInterval: 0.4) // wait for animation still
        }
        try waitForReplyTranscriptsClose()
    }

    private func waitUntilReplyTranscriptVisible() throws {
        debugLog("waitUntilReplyTranscriptVisible")
        try retry(withTimeout: 1.2, interval: 0.1) {
            guard let pValue = try? elements.messageBodyField.placeholderValue(),
                pValue != LocalizedStrings.imessage && pValue != LocalizedStrings.textMessage else {
                throw ErrorMessage("replyTranscriptView not visible")
            }
        }
    }

    private func sendReplyWithoutOverlay(threadID: String, quotedMessage: MessageCell, text: String?, filePath: String?) throws {
        try withMessageCell(threadID: threadID, messageCell: quotedMessage) {
            let replyAction = try messageAction(messageCell: $0, action: .reply)
            try replyAction()
            let messageField = try elements.messageBodyField
            if let text = text {
                try assignToMessageField(messageField, text: text)
            } else if let filePath = filePath {
                try pasteFileInBodyField(messageField, filePath: filePath)
            }
            try sendMessageInField(messageField)
        }
    }

    // this method has a lot of combinations, test carefully
    func sendMessage(threadID: String?, addresses: [String]?, text: String?, filePath: String?, quotedMessage: MessageCell?) throws {
        let startTime = Date()
        defer { Logger.log("sendMessage took \(startTime.timeIntervalSinceNow * -1000)ms") }

        let url: URL
        if let quotedMessage = quotedMessage {
            url = try MessagesDeepLink.message(guid: quotedMessage.messageGUID, overlay: quotedMessage.overlay).url()
        } else if let threadID = threadID {
            url = try MessagesDeepLink(threadID: threadID, body: text).url()
        } else if let addresses = addresses {
            url = try MessagesDeepLink.addresses(addresses, body: text).url()
        } else {
            throw ErrorMessage("not implemented")
        }

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        // this isn't reliable so we use pasteFileInBodyField:
        // if let filePath = filePath {
        //     guard let address = threadIDToAddress(threadID) else { throw ErrorMessage("invalid threadID") }
        //     try withAllWindowsClosed {
        //         try DraftsManager.saveDraft(address: String(address), filePath: filePath)
        //     }
        // }
        if let quotedMessage = quotedMessage, !quotedMessage.overlay, let threadID = threadID {
            return try sendReplyWithoutOverlay(threadID: threadID, quotedMessage: quotedMessage, text: text, filePath: filePath)
        }

        if quotedMessage == nil { try? closeReplyTranscriptView() } // needed even when opening deep link

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            if let threadID = threadID { try ensureSelectedThread(threadID: threadID) }

            if quotedMessage != nil {
                try waitUntilReplyTranscriptVisible()
            }
            if Defaults.isSelectedThreadCellCompose() {
                // since this is a new thread not in contacts, it may take a while for messages app to resolve that the address is imessage and not just sms
                debugLog("waiting 1.5s for address to resolve")
                Thread.sleep(forTimeInterval: 1.5)
            }

            let messageField = try elements.messageBodyField
            if let text = text {
                if quotedMessage != nil { // text has to be manually assigned when quoted since ?body in deep link doesn't take any effect
                    try assignToMessageField(messageField, text: text)
                }
                try sendMessageInField(messageField)
            } else if let filePath = filePath {
                try pasteFileInBodyField(messageField, filePath: filePath)
                try sendMessageInField(messageField)
            }
        }
    }

    #if DEBUG
    func closeAllWindows() throws {
        try elements.mainWindow.closeWindow()
        try elements.app.appWindows().forEach { try $0.closeWindow() }
    }

    func withAllWindowsClosed(perform: () throws -> Void) throws {
        try closeAllWindows()
        try perform()
        _ = try elements.mainWindow // accessing will open it
    }

    func assignFileToBodyField(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        print(data, url)

        let myString = "something"
        let myAttrString = NSAttributedString(string: myString, attributes: [:])
        let mas = NSMutableAttributedString()
        mas.append(myAttrString)

        let messageField = try elements.messageBodyField
        try messageField.value(assign: url) // no op
        try messageField.value(assign: mas) // illegalArgument
        try messageField.value(assign: data) // cannotComplete

        try messageField.value(assign: "\u{fffc}") // obj replacement char
        try messageField.value(assign: url)
    }
    #endif

    func pasteFileInBodyField(_ messageField: Accessibility.Element, filePath: String) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        try? messageField.value(assign: "")
        focusMessageField(messageField) // focus is partially redundant, hitting ⌘ V without focus works too unless another text field is focused
        let pasteboard = NSPasteboard.general
        try pasteboard.withRestoration {
            pasteboard.setString(fileURL.relativeString, forType: .fileURL)
            try keyPresser.commandV()
            try retry(withTimeout: 2, interval: 0.1) {
                // 2 for <OBJ_REPLACEMENT_CHAR> and \n
                let charCountResult = Result { try messageField.noOfChars() }
                guard case let .success(charCount) = charCountResult, charCount == 2 else {
                    throw ErrorMessage("file was not pasted. \(charCountResult) \(messageField.isInViewport)")
                }
            }
        }
    }

    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        do {
            debugLog("activateMessages")
            // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
            let window = elements.getMainWindow()
            try whm.appActivated(window: window)
        } catch {
            debugLog("warning: Could not show Messages window: \(error)")
        }
    }

    private func deactivateMessages() {
        do {
            debugLog("deactivateMessages")
            // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
            try whm.appDeactivated(window: elements.getMainWindow())
        } catch {
            debugLog("warning: Could not hide Messages window: \(error)")
        }
    }

    private func activityStatus() -> [ActivityStatus] {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("activityStatus took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        guard let transcript = try? elements.transcriptView,
              let count = try? transcript.children.count() else {
            return [.unknown]
        }
        let cellsToCheck: [Accessibility.Element]
        switch count {
        case 0:
            return [.unknown]
        case 1:
            guard let elt = try? transcript.children.value(at: 0) else {
                return [.unknown]
            }
            cellsToCheck = [elt]
        default:
            // todo review if 2 : 1 is enough
            let lastN = isMontereyOrUp ? 3 : 2
            guard let elts = try? transcript.children(range: (count - lastN)..<count), elts.count == lastN else {
                return [.unknown]
            }
            cellsToCheck = elts
        }
        // AXStaticText, localizedDescription="￼ Steve has notifications silenced"
        // AXButton, localizedDescription="Notify Anyway"
        let dndFlag: ActivityStatus? = {
            guard isMontereyOrUp else { return nil }
            for elt in cellsToCheck.reversed() {
                guard let child = try? elt.children.value(at: 0) else { continue }
                if (try? child.role()) == AXRole.button,
                   (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway {
                    return .dndCanNotify
                } else if (try? child.role()) == AXRole.staticText,
                          (try? child.localizedDescription())?.hasSuffix(LocalizedStrings.hasNotificationsSilencedSuffix) == true {
                    return .dnd
                }
            }
            return nil
        }()
        let isTyping = cellsToCheck.contains { elt in
            // children can briefly be 0 for newly sent messages as well, so
            // that by itself isn't a good enough heuristic
            (try? elt.children.count()) == 0 && (try? elt.roleDescription().isEmpty) != false
        }
        let flags: [ActivityStatus] = (isTyping ? [.typing] : [.notTyping]) + (dndFlag.flatMap { [$0] } ?? [])
        return flags
    }

    func notifyAnyway(threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try ensureSelectedThread(threadID: threadID)
            try elements.notifyAnywayButton.press()
        }
    }

    /* TODO: Switch to os_unfair_lock if we drop old OSes, or maybe determine the lock we use dynamically.
        activityLock.lock() called by:
        MessagesController.observe()
        MessagesController.removeObserver()
        MessagesController.sendMessage()
        MessagesController.setReaction()
        MessagesController.sendTypingStatus()
        MessagesController.notifyAnyway()
        MessagesController.toggleThreadRead()
        MessagesController.muteThread()
        MessagesController.deleteThread()
    */
    private let activityLock = NSLock()

    // called on run loop thread, not main node thread
    private func pollActivityStatus() {
        guard let observer = activityObserver else { return }
        // if someone else (observe/removeObserver) holds the lock,
        // silently skip this polling attempt
        guard activityLock.try() else { return }
        defer { activityLock.unlock() }

        debugLog("pollActivityStatus")

        guard isValid else {
            debugLog("pollActivityStatus: invalid MessagesController")
            return
        }

        let selectedThread = Defaults.getSelectedThreadID().flatMap(splitThreadID)
        let observerAddress = threadIDToAddress(observer.threadID)
        guard let (_, type, selectedAddress) = selectedThread,
              (selectedAddress == observerAddress ||
              (type == singleThreadType && isSameContact(selectedAddress, observerAddress))) else {
            debugLog("pollActivityStatus: selected thread changed, not polling \(observer.threadID)")
            observer.send([.unknown])
            return
        }

        observer.send(activityStatus())
    }

    // must call with lock held
    private func _removeObserver() throws {
        if let old = activityObserver {
            old.send([.notTyping])
            activityObserver = nil
        }
    }

    func removeObserver() throws {
        activityLock.lock()
        defer { activityLock.unlock() }
        try _removeObserver()
    }

    func observe(threadID: String, callback: @escaping ([ActivityStatus]) -> Void) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        // we remove the previous observer first, so that if
        // this method fails we don't keep sending notifs to the old
        // observer. We only update to the new observer once we've
        // successfully switched chats.
        try _removeObserver()

        try Self.openDeepLink(url)
        activityObserver = .init(threadID: threadID, url: url, callback: callback)
    }

    private var isDisposed = false

    func dispose() {
        debugLog("Disposing MessagesController...")
        guard !isDisposed else { return }
        NotificationCenter.default.removeObserver(self, name: .CNContactStoreDidChange, object: nil)
        isDisposed = true
        timer?.invalidate()
        loopThread?.cancel()
        app.terminate()
        whm.dispose()
    }

    deinit {
        debugLog("deinit")
        dispose()
    }
}
