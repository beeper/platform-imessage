import AppKit
import AccessibilityControl
import WindowControl
import Carbon.HIToolbox.Events
import PHTClient

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { message }
}

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

let isMontereyOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0))

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
        let address: String
        let url: URL
        let windowTitle: String

        // may be called on a bg thread
        private let callback: ([ActivityStatus]) -> Void

        private var lastSent: [ActivityStatus] = [.notTyping]
        private var lastSentTime = Date()

        init(address: String, url: URL, windowTitle: String, callback: @escaping ([ActivityStatus]) -> Void) {
            self.address = address
            self.url = url
            self.windowTitle = windowTitle
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

    private static let messagesBundleID = "com.apple.MobileSMS"
    private static let focusSettingsUIBundle = isMontereyOrUp ? Bundle(path: "/System/Library/PrivateFrameworks/FocusSettingsUI.framework") : nil
    private static let hasNotificationsSilencedSuffix = focusSettingsUIBundle.flatMap { $0.localizedString(forKey: "AVAILABILITY_STATUS_EXAMPLE_%@", value: nil, table: nil).replacingOccurrences(of: "%@", with: "") }
    private static let notifyAnywayString = focusSettingsUIBundle.flatMap { $0.localizedString(forKey: "AVAILABILITY_STATUS_EXAMPLE_NOTIFY_ANYWAY", value: nil, table: nil) }

    private static let messagesUserDefaults = UserDefaults(suiteName: messagesBundleID)

    private static let pollingInterval: TimeInterval = 1

    private let app: NSRunningApplication
    private let appElement: Accessibility.Element

    private let phtConn: PHTConnection?

    private var timer: Timer?
    private var loopThread: RunLoopThread?

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?

    private var activityObserver: ActivityObserver?

    private let whm: WindowHidingManager

    // this increases the viewport height so that mark as read works more reliably
    private static func resizeWindowToMaxHeight(_ window: Accessibility.Element) throws {
        var frame = try window.frame()
        frame.origin.y = 0
        frame.size.height = Double.infinity
        try window.setFrame(frame)
    }

    private static func closeWindow(_ window: Accessibility.Element) throws {
        guard let closeButton = try? window.windowCloseButton() else {
            throw ErrorMessage("window close button not found")
        }
        try closeButton.press()
    }

    static func terminateApp(_ app: NSRunningApplication) throws {
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
    private static func openDeepLink(_ url: URL, withoutActivation: Bool) throws -> NSRunningApplication {
        debugLog("Opening deep link: \(url) withoutActivation=\(withoutActivation)")
        return try NSWorkspace.shared.open(
            url,
            options: withoutActivation ? [.andHide, .withoutActivation] : [.andHide],
            configuration: [:]
        )
    }

    static func getRunningMessagesApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID)
    }

    static func resetPrompts() {
        // Self.messagesUserDefaults?.set(true, forKey: "kHasSetupHashtagImages") // unknown
        Self.messagesUserDefaults?.set(true, forKey: "SMSRelaySettingsConfirmed") // unknown
        Self.messagesUserDefaults?.set(true, forKey: "ReadReceiptSettingsConfirmed")
        Self.messagesUserDefaults?.set(2, forKey: "BusinessChatPrivacyPageDisplayed")
    }

    func isPromptVisibleInMessagesApp() -> Bool {
        allWindows.contains(where: { (try? $0.windowCloseButton().isEnabled()) == false })
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
                app = try launchMessages(true)
            }
        } else {
            // we launch with activation because mark as read doesn't work until the app is activated at least once
            app = try launchMessages(false)
        }

        let start = Date()
        // without sleeping, appElement.observe applicationActivated/applicationDeactivated doesn't fire
        while !app.isFinishedLaunching {
            debugLog("sleeping 0.1s for messages.app to finish launching")
            Thread.sleep(forTimeInterval: 0.1)
            if app.isTerminated {
                throw ErrorMessage("messages.app terminated")
            }
            if start.timeIntervalSinceNow < -5 {
                debugLog("assuming messages.app has launched") // sometimes this gets stuck in an infinite loop
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)

        appElement = Accessibility.Element(pid: app.processIdentifier)

        if SwiftServer.isPHTEnabled {
            let phtConn = try PHTConnection.create(allowInstall: true)
            try phtConn.setMessagesHidden(true)
            self.phtConn = phtConn
        } else {
            self.phtConn = nil
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
            self.activateToken = try? self.appElement.observe(.applicationActivated) { [weak self] _ in
                self?.activateMessages()
            }
            self.deactivateToken = try? self.appElement.observe(.applicationDeactivated) { [weak self] _ in
                self?.deactivateMessages()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
        self.loopThread = thread

        guard self.isValid else {
            throw ErrorMessage("Initialized MessagesController in an invalid state")
        }
    }

    var isValid: Bool {
        !app.isTerminated && (try? mainWindow.isFrameValid) != nil && whm.isValid
    }

    private func selectedThreadCell() -> Accessibility.Element? {
        try? conversationsList.selectedChildren.value(at: 0)
    }

    private var allWindows: [Accessibility.Element] {
        get {
            // after a window is moved to the new space, AX doesn't list the window in appWindows or children
            (((try? appElement.appWindows()) ?? []) + [try? appElement.appMainWindow(), try? appElement.appFocusedWindow()]).compactMap { $0 }
        }
    }

    private func getMainWindow() -> Accessibility.Element? {
        allWindows.first(where: {
            // note: don't detect presence of AXSplitter here, it's unreliable
            $0.child(withID: "ConversationList") != nil ||
                $0.child(withID: "CKConversationListCollectionView") != nil
        })
    }

    private var cachedMainWindow: Accessibility.Element?
    private var cachedConversationsList: Accessibility.Element?
    private var cachedTranscriptsView: Accessibility.Element?
    private var cachedReplyTranscriptsView: Accessibility.Element?

    private func clearCachedElements() {
        // these are manually cleared because we aren't checking for validity on each property access
        // for cachedConversationsList, isValid/isFrameValid/isInViewport all return true even after the main window is closed
        cachedConversationsList = nil
        cachedTranscriptsView = nil
        cachedReplyTranscriptsView = nil
    }

    private var mainWindow: Accessibility.Element {
        get throws {
            if let cached = cachedMainWindow, cached.isFrameValid {
                return cached
            }
            let mainWindow = try retry(withTimeout: 5, interval: 0.2) { () throws -> Accessibility.Element in
                try getMainWindow().orThrow(ErrorMessage("Could not get main Messages window"))
            } onError: { attempt, _ in
                if attempt == 0 {
                    debugLog("Opening compose deep link to get main window")
                    try Self.openDeepLink(MessagesDeepLink.compose.url(), withoutActivation: true)
                } else if attempt == 1 {
                    if self.isPromptVisibleInMessagesApp() {
                        Self.resetPrompts()
                    }
                } else if attempt == 2 {
                    if self.isPromptVisibleInMessagesApp() {
                        // regular terminate wont work since all window close buttons are disabled
                        self.app.forceTerminate()
                        // this should invalidate the MessagesController
                    }
                }
            }
            try? Self.resizeWindowToMaxHeight(mainWindow)
            try? whm.mainWindowChanged(mainWindow)
            clearCachedElements()
            cachedMainWindow = mainWindow
            return mainWindow
        }
    }

    private var conversationsList: Accessibility.Element {
        get throws {
            if let cached = cachedConversationsList {
                return cached
            }
            let cl = try retry(withTimeout: 1, interval: 0.2) {
                try mainWindow.child(withID: "ConversationList")
                    .orThrow(ErrorMessage("Could not find ConversationList"))
            } onError: { _, _ in
                let searchField = try self.searchField()
                debugLog("Getting ConversationList errored, calling searchField.cancel")
                // this will close the search results if active
                try searchField.cancel()
            }
            cachedConversationsList = cl
            return cl
        }
    }

    private func messageAction(targetCell: Accessibility.Element, name: String, overlay: Bool) throws -> Accessibility.Action {
        let allActions = try targetCell.supportedActions()
        // non-AX actions are [React, Reply, Copy, Pin]
        // Pin is missing for non-links / Big Sur
        if overlay {
            guard let action = allActions.first(where: { $0.name.value.hasPrefix("Name:\(name)") }) else {
                throw ErrorMessage("Could not find \(name) action")
            }
            return action
        } else {
            let customActions = allActions.filter { !$0.name.value.hasPrefix("AX") }
            guard customActions.count >= 2 else {
                throw ErrorMessage("Could not find message actions")
            }
            guard let idx = ["React", "Reply"].firstIndex(of: name) else {
                throw ErrorMessage("Unknown \(name) action")
            }
            let action = customActions[idx]
            return action
        }
    }

    private func reactButtons(targetCell: Accessibility.Element, overlay: Bool) throws -> [Accessibility.Element] {
        let reactAction = try messageAction(targetCell: targetCell, name: "React", overlay: overlay)
        try reactAction()
        let reactionsView = try reactionsView()
        guard let buttons = try? reactionsView.children().filter({ (try? $0.role()) == AXRole.button }) else {
            throw ErrorMessage("Could not find reaction buttons")
        }
        /*
         8 `AXButton`s
         Heart
         Thumbs up
         Thumbs down
         Ha ha!
         Exclamation mark
         Question mark
         Reply -- only shows up when not in overlay mode
         Pin -- only shows up for links/tweets in Monterey or above
         */
        guard buttons.count > 0 else {
            throw ErrorMessage("\(buttons.count) buttons found in reactionsView")
        }
        return buttons
    }

    private func getTranscriptsView(replyTranscripts: Bool) throws -> Accessibility.Element {
        func isReplyTranscriptsView(_ el: Accessibility.Element) -> Bool {
            // alternative: (localizedDescription == "Messages" when not overlayed)
            // (try? el.localizedDescription()) == "Reply transcript"
            // when reply is active, linkedElements.count = 1 (the sole linked element is messageBodyField)
            (try? el.linkedElements.count()) ?? 0 == 0
        }
        return try mainWindow.recursiveChildren().lazy.first {
            (try? $0.identifier()) == "TranscriptCollectionView" && isReplyTranscriptsView($0) == replyTranscripts
        }
        .orThrow(ErrorMessage("Could not find TranscriptCollectionView, replyTranscripts=\(replyTranscripts)"))
    }

    private var transcriptsView: Accessibility.Element {
        get throws {
            if let cached = cachedTranscriptsView, cached.isInViewport {
                return cached
            }
            let tcv = try getTranscriptsView(replyTranscripts: false)
            cachedTranscriptsView = tcv
            return tcv
        }
    }

    private var replyTranscriptsView: Accessibility.Element {
        get throws {
            if let cached = cachedReplyTranscriptsView, cached.isInViewport {
                return cached
            }
            let tcv = try getTranscriptsView(replyTranscripts: true)
            cachedReplyTranscriptsView = tcv
            return tcv
        }
    }

    private func messagesField() throws -> Accessibility.Element {
        try retry(withTimeout: 1.5, interval: 0.25) {
            try mainWindow.child(withID: "messageBodyField")
                .orThrow(ErrorMessage("Could not find messageBodyField"))
        }
    }

    private func searchField() throws -> Accessibility.Element {
        try retry(withTimeout: 1.5, interval: 0.25) {
            let CKConversationListCollectionView = try mainWindow.child(withID: "CKConversationListCollectionView")
                .orThrow(ErrorMessage("Could not find CKConversationListCollectionView"))
            return try CKConversationListCollectionView.children().first { (try? $0.subrole()) == AXRole.searchField }
                .orThrow(ErrorMessage("Could not find searchField"))
        }
    }

    private func reactionsView() throws -> Accessibility.Element {
        try retry(withTimeout: 1.5, interval: 0.25) {
            guard let mainView = try mainWindow.children().first(where: { (try? $0.role()) == AXRole.group }),
                  // (try? mainView.children.count()) ?? 0 >= 2,
                  let presView = try? mainView.children.value(at: 0),
                  (try? presView.children.count()) ?? 0 > 0 else {
                throw ErrorMessage("Could not find reactions view")
            }
            return presView
        }
    }

    @discardableResult
    private func waitUntilSelectedThreadCell(isCompose: Bool, timeout: TimeInterval = 1) -> Accessibility.Element? {
        try? retry(withTimeout: timeout, interval: 0.01) { () throws -> Accessibility.Element in
            guard let selected = selectedThreadCell() else { throw ErrorMessage("selected != selectedThreadCell") }
            let isActuallyCompose = Self.isThreadCellCompose(selected)
            guard isCompose == isActuallyCompose else { throw ErrorMessage("isCompose != isActuallyCompose") }
            return selected
        }
    }

    // performs `perform` while the Messages window is unhidden. Returns the new window title
    @discardableResult
    private func withActivation(
        openBefore: URL?, openAfter: URL?,
        perform: () throws -> Void
    ) throws -> String? {
        if let openBefore = openBefore {
            try Self.openDeepLink(openBefore, withoutActivation: true)
        }

        try perform()

        let newTitle: String?
        if let openAfter = openAfter {
            debugLog("withActivation: Returning to openAfter \(openAfter)")
            let oldTitle = try mainWindow.title()
            try Self.openDeepLink(openAfter, withoutActivation: true)
            newTitle = try? retry(withTimeout: 1, interval: 0.1) {
                let newTitle = try mainWindow.title()
                // the message doesn't matter since we're try?-ing
                guard newTitle != oldTitle else { throw ErrorMessage("") }
                return newTitle
            }
        } else {
            newTitle = nil
        }

        return newTitle
    }

    private static func isThreadCellCompose(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription()) == nil
    }

    private static func isMessageContainerCell(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription())?.isEmpty == false &&
            (try? el.children.value(at: 0).supportedActions().contains(where: { $0.name.value.hasPrefix("Name:React") })) == true
    }

    private static func messageContainerCells(in tv: Accessibility.Element) throws -> [Accessibility.Element] {
        try tv.children().filter(Self.isMessageContainerCell)
    }

    private static func firstMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        try tv.children().first(where: Self.isMessageContainerCell)?.children.value(at: 0)
    }
    private static func firstSelectedMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        // selectedChildren wont work here
        // tv.children().first { (try? $0.selectedChildren.value(at: 0)) != nil }?.children.value(at: 0)
        try tv.children().first { (try? $0.children.value(at: 0).isSelected()) == true }?.children.value(at: 0)
    }

    private func withMessageCell(guid: String, offset: Int, cellID: String?, cellRole: String?, overlay: Bool, action: (_ cell: Accessibility.Element) throws -> Void) throws {
        debugLog("Finding cell at offset \(offset) from \(guid)")

        let url = try MessagesDeepLink.message(guid: guid, overlay: overlay).url()

        // without closing reply transcripts, non-overlay deep link won't select the message
        if !overlay, let rtv = try? replyTranscriptsView {
            debugLog("calling replyTranscriptsView.cancel()")
            try? rtv.cancel()
        }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            // we don't close transcripts view here because when reacting, closing it will undo the reaction
            // defer {
            //     if overlay {
            //         // alt: try? sendKeyPress(key: CGKeyCode(kVK_Escape))
            //         Thread.sleep(forTimeInterval: 0.1)
            //         try? replyTranscriptsView.cancel()
            //     }
            // }
            // wait for animation
            if overlay { Thread.sleep(forTimeInterval: 0.5) }
            guard let selected = (try retry(withTimeout: 1, interval: 0.2) { () -> Accessibility.Element? in
                guard let cell = try overlay ? Self.firstMessageCell(in: replyTranscriptsView) : Self.firstSelectedMessageCell(in: transcriptsView) else {
                    throw ErrorMessage("")
                }
                guard cell.isInViewport else { throw ErrorMessage("") }
                return cell
            }) else {
                throw ErrorMessage("Could not find message cell")
            }
            let targetCell: Accessibility.Element
            if offset == 0 {
                targetCell = selected
            } else {
                let containerCell = try selected.parent()
                let containerFrame = try containerCell.frame()
                let containerCells = try Self.messageContainerCells(in: overlay ? replyTranscriptsView : transcriptsView)
                guard let idx = containerCells.firstIndex(where: { (try? $0.frame()) == containerFrame }) else {
                    throw ErrorMessage("Could not find target message cell")
                }
                let target = idx - offset
                debugLog("Index: \(idx) - \(offset) = \(target)")
                guard containerCells.indices.contains(target) else {
                    throw ErrorMessage("Desired index out of bounds")
                }
                targetCell = try containerCells[target].children.value(at: 0)
            }
            if let cellRole = cellRole, let role = try? targetCell.role() {
                guard role == cellRole else {
                    debugLog("Expected cell role \(cellRole), got \(role)")
                    throw ErrorMessage("Cell role mismatch")
                }
            }
            if let cellID = cellID, let id = try? targetCell.identifier() {
                guard id == cellID else {
                    debugLog("Expected cell id \(cellID), got \(id)")
                    throw ErrorMessage("Cell id mismatch")
                }
            }
            try action(targetCell)
        }
    }

    func setReaction(messageGUID: String, offset: Int, cellID: String?, cellRole: String?, overlay: Bool, reaction: Reaction, on: Bool) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        let idx = reaction.index
        try withMessageCell(guid: messageGUID, offset: offset, cellID: cellID, cellRole: cellRole, overlay: overlay) { targetCell in
            let buttons = try reactButtons(targetCell: targetCell, overlay: overlay)

            let btn = buttons[idx]
            try retry(withTimeout: 1, interval: 0.2) {
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

    func markAsRead(messageGUID: String) throws {
        let url = try MessagesDeepLink.message(guid: messageGUID, overlay: false).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        let compose = try MessagesDeepLink.compose.url()
        try withActivation(openBefore: compose, openAfter: activityObserver?.url) {
            guard let composeCell = waitUntilSelectedThreadCell(isCompose: true) else {
                throw ErrorMessage("Compose thread cell not found")
            }

            debugLog("Opened compose. Opening target thread")
            try Self.openDeepLink(url, withoutActivation: true)

            // Thread.sleep(forTimeInterval: 1)
            // debugLog("Deleting compose")
            // guard let deleteAction = try composeCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:Delete") }) else {
            //     throw ErrorMessage("composeCell.deleteAction not found")
            // }
            // // this will scroll to the selected cell
            // try deleteAction()
            // Thread.sleep(forTimeInterval: 1)

            guard let targetCell = waitUntilSelectedThreadCell(isCompose: false) else {
                throw ErrorMessage("Thread cell with message \(messageGUID) not found")
            }

            // Thread.sleep(forTimeInterval: 1)
            // we now click another cell and then come back

            debugLog("Pressing compose thread cell")
            try composeCell.press()
            waitUntilSelectedThreadCell(isCompose: true)

            // Thread.sleep(forTimeInterval: 1)
            debugLog("Pressing target thread cell")
            try targetCell.press()
            waitUntilSelectedThreadCell(isCompose: false)

            debugLog("Done!")
        }
    }

    #if DEBUG
    func markAsReadWithMenu(messageGUID: String) throws {
        let url = try MessagesDeepLink.message(guid: messageGUID, overlay: false).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            _ = selectedThreadCell()
            guard let targetCell = waitUntilSelectedThreadCell(isCompose: false) else {
                throw ErrorMessage("Thread cell with message \(messageGUID) not found")
            }
            try targetCell.showMenu()

            // Thread.sleep(forTimeInterval: 1)
            guard let group = (try retry(withTimeout: 1, interval: 0.1) { try mainWindow.children().first(where: { try $0.role() == AXRole.group }) }) else {
                throw ErrorMessage("Could not find main view")
            }
            guard let menu = (try retry(withTimeout: 4, interval: 0.5) { try group.children().first(where: { try $0.role() == AXRole.menu }) }) else {
                throw ErrorMessage("Could not find menu")
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
            guard let markAsReadMenuItem = try menu.children().first(where: { (try? $0.identifier()) == "mark_as_read" }) else {
                throw ErrorMessage("Could not find mark as read menu item")
            }
            try markAsReadMenuItem.press()
        }
    }
    #endif

    func muteThread(threadID: String, muted: Bool) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            // review: this is strangely needed, without this the currently observed thread is muted
            _ = selectedThreadCell()
            guard let targetCell = waitUntilSelectedThreadCell(isCompose: false) else {
                throw ErrorMessage("Cell for thread \(threadID) not found")
            }
            guard let muteAction = try targetCell.supportedActions().first(where: { $0.name.value.hasPrefix(muted ? "Name:Hide Alerts" : "Name:Show Alerts") }) else {
                throw ErrorMessage("muteAction not found")
            }
            try muteAction()
        }
    }

    func deleteThread(threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            // review: copied over from muteThread
            // this is a destructive method and can delete the wrong thread if targetCell is incorrect
            _ = selectedThreadCell()
            guard let targetCell = waitUntilSelectedThreadCell(isCompose: false) else {
                throw ErrorMessage("Cell for thread \(threadID) not found")
            }
            guard let deleteAction = try targetCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:Delete") }) else {
                throw ErrorMessage("deleteAction not found")
            }
            try deleteAction()
            guard let alertSheet = try mainWindow.children().first(where: { try $0.role() == AXRole.sheet }) else {
                throw ErrorMessage("alertSheet not found")
            }
            guard let deleteButton = try alertSheet.children().first(where: { try $0.role() == AXRole.button }) else {
                throw ErrorMessage("deleteButton not found")
            }
            try deleteButton.press()
        }
    }

    func sendTypingStatus(_ isTyping: Bool, address: String) throws {
        debugLog("Sending typing status \(isTyping) for address \(address)")

        // a space is enough to send a typing indicator, while ensuring that
        // users can't accidentally hit return to send a single-char message
        // (since Messages special-cases space-only messages). The NUL byte
        // is another option that doesn't get sent to the server, but it
        // shows up client-side as a ghost message.
        let url = try MessagesDeepLink.addresses([address], body: isTyping ? " " : nil).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        let initialTitle = try? mainWindow.title()

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            if isTyping { return } // no further action required

            try? retry(withTimeout: 1, interval: 0.2) {
                guard try mainWindow.title() != initialTitle else {
                    throw ErrorMessage("")
                }
            }

            try messagesField().value(assign: "")
        }
    }

    private func sendKeyPress(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        for keyDown in [true, false] {
            debugLog("Sending key \(key) \(keyDown ? "down" : "up")")
            let ev = try CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("Could not send key \(key)"))
            if let flags = flags { ev.flags = flags }
            ev.postToPid(app.processIdentifier)
        }
    }
    private func sendKeyPressOnMainThread(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        debugLog("sendKey key=\(key) Thread.isMainThread=\(Thread.isMainThread) queueName=\(__dispatch_queue_get_label(nil))")
        if Thread.isMainThread {
            try sendKeyPress(key: key, flags: flags)
        } else {
            try DispatchQueue.main.sync {
                try sendKeyPress(key: key, flags: flags)
            }
        }
    }
    private func sendReturnPress() throws {
        try sendKeyPressOnMainThread(key: CGKeyCode(kVK_Return))
    }
    private func sendCommandVPress() throws {
        try sendKeyPressOnMainThread(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    private func focusMessageField(_ messageField: Accessibility.Element) throws {
        try retry(withTimeout: 1, interval: 0.25) {
            // this doesn't ever focus in compose thread for some reason
            try messageField.isFocused(assign: true)
            guard try messageField.isFocused() else {
                throw ErrorMessage("Could not focus message field")
            }
        }
    }

    private func assignToMessageField(_ messageField: Accessibility.Element, text: String) throws {
        try retry(withTimeout: 1, interval: 0.25) {
            try messageField.value(assign: text)
            guard (try? messageField.value() as? String) == text else {
                throw ErrorMessage("Could not assign value to message field")
            }
        }
    }

    private func sendMessageInField(_ messageField: Accessibility.Element) throws {
        try focusMessageField(messageField) // focus is partially redundant, hitting enter without focus works too unless another text field is focused
        try self.sendReturnPress()
        try retry(withTimeout: 1.5, interval: 0.25) {
            if let message = try? messageField.value() as? String, !message.isEmpty {
                let hasNewline = message.hasSuffix("\n")
                throw ErrorMessage("Could not send message\(hasNewline ? " (extraneous newline)" : "")")
            }
        } onError: { (attempt, _ ) in
            if attempt == 5 { // penultimate attempt
                try? self.sendReturnPress()
            }
        }
    }

    // the URL should be a deep link that fills the text field with the required message
    // (in the appropriate thread)
    private func sendTextMessage(url: URL) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        let initialTitle = try? mainWindow.title()

        if let rtv = try? replyTranscriptsView {
            debugLog("calling replyTranscriptsView.cancel()")
            try? rtv.cancel()
            Thread.sleep(forTimeInterval: 0.2) // wait for animation
        }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try? retry(withTimeout: 1, interval: 0.2) {
                guard try mainWindow.title() != initialTitle else {
                    throw ErrorMessage("")
                }
            }

            let messageField = try messagesField()
            try sendMessageInField(messageField)
        }
    }

    func sendTextMessage(_ text: String, threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: text).url()
        try sendTextMessage(url: url)
    }

    func sendFile(_ filePath: String, threadID: String) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        try Self.openDeepLink(url, withoutActivation: true)
        Thread.sleep(forTimeInterval: 0.01)

        let messageField = try messagesField()
        try self.pasteFileInBodyField(messageField, filePath: filePath)
        try sendMessageInField(messageField)
    }

    func createThread(addresses: [String], message: String) throws {
        let url = try MessagesDeepLink.addresses(addresses, body: message).url()
        if let selected = selectedThreadCell(), Self.isThreadCellCompose(selected) {
            // since this is a new thread not in contacts, it may take a while for messages app to resolve that the address is imessage and not just sms
            Thread.sleep(forTimeInterval: 1)
        }
        try sendTextMessage(url: url)
    }

    #if DEBUG
    func closeAllWindows() throws {
        try Self.closeWindow(mainWindow)
        try appElement.appWindows().forEach(Self.closeWindow)
    }

    func withAllWindowsClosed(perform: () throws -> Void) throws {
        try closeAllWindows()
        try perform()
        _ = try mainWindow // accessing will open it
    }

    func assignFileToBodyField(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        print(data, url)

        let myString = "something"
        let myAttrString = NSAttributedString(string: myString, attributes: [:])
        let mas = NSMutableAttributedString()
        mas.append(myAttrString)

        let messageField = try messagesField()
        try messageField.value(assign: url) // no op
        try messageField.value(assign: mas) // illegalArgument
        try messageField.value(assign: data) // cannotComplete

        try messageField.value(assign: "\u{fffc}") // obj replacement char
        try messageField.value(assign: url)
    }
    #endif

    func pasteFileInBodyField(_ messageField: Accessibility.Element, filePath: String) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        try assignToMessageField(messageField, text: "")
        try focusMessageField(messageField) // focus is partially redundant, hitting ⌘ V without focus works too unless another text field is focused
        let pasteboard = NSPasteboard.general
        try pasteboard.withRestoration {
            pasteboard.setString(fileURL.relativeString, forType: .fileURL)
            try self.sendCommandVPress()
            try retry(withTimeout: 2, interval: 0.1) {
                // 2 for <OBJ_REPLACEMENT_CHAR> and \n
                guard (try? messageField.noOfChars()) == 2 else { throw ErrorMessage("file was not pasted") }
            }
        }
    }

    func sendReply(threadID: String, messageGUID: String, offset: Int, cellID: String?, cellRole: String?, overlay: Bool, text: String?, filePath: String?) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        func send(_ messageField: Accessibility.Element) throws {
            if let text = text {
                try assignToMessageField(messageField, text: text)
            }
            try sendMessageInField(messageField)
        }

        // this isn't reliable so we use pasteFileInBodyField:
        // if let filePath = filePath {
        //     guard let address = threadID.split(separator: ";", maxSplits: 2).last else { throw ErrorMessage("invalid threadID") }
        //     try withAllWindowsClosed {
        //         try DraftsManager.saveDraft(address: String(address), filePath: filePath)
        //     }
        // }

        if overlay {
            let url = try MessagesDeepLink.message(guid: messageGUID, overlay: overlay).url()
            try Self.openDeepLink(url, withoutActivation: true)
            Thread.sleep(forTimeInterval: 0.1)

            let messageField = try messagesField()
            if let filePath = filePath {
                try self.pasteFileInBodyField(messageField, filePath: filePath)
            }

            try send(messageField)
            return
        }

        try withMessageCell(guid: messageGUID, offset: offset, cellID: cellID, cellRole: cellRole, overlay: overlay) { targetCell in
            let replyAction = try messageAction(targetCell: targetCell, name: "Reply", overlay: overlay)
            try replyAction()
            let messageField = try messagesField()
            try send(messageField)
        }
    }

    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        do {
            debugLog("activateMessages")
            if getMainWindow() != nil { // this check is to make sure accessing mainWindow doesn't reopen the window and hide it
                try whm.appActivated(window: mainWindow)
            } else {
                debugLog("activateMessages: mainWindow nil")
            }
            try phtConn?.setMessagesHidden(false)
        } catch {
            debugLog("warning: Could not show Messages window: \(error)")
        }
    }

    private func deactivateMessages() {
        do {
            debugLog("deactivateMessages")
            if getMainWindow() != nil { // this check is to make sure accessing mainWindow doesn't reopen the window
                try? Self.resizeWindowToMaxHeight(mainWindow)
                try whm.appDeactivated(window: mainWindow)
            } else {
                debugLog("deactivateMessages: mainWindow nil")
            }
            try phtConn?.setMessagesHidden(true)
        } catch {
            debugLog("warning: Could not hide Messages window: \(error)")
        }
    }

    private func activityStatus() -> [ActivityStatus] {
        guard let transcripts = try? transcriptsView,
              let count = try? transcripts.children.count() else {
            return [.unknown]
        }
        let cellsToCheck: [Accessibility.Element]
        switch count {
        case 0:
            return [.unknown]
        case 1:
            guard let elt = try? transcripts.children.value(at: 0) else {
                return [.unknown]
            }
            cellsToCheck = [elt]
        default:
            // todo review if 2 : 1 is enough
            let lastN = isMontereyOrUp ? 3 : 2
            guard let elts = try? transcripts.children(range: (count - lastN)..<count), elts.count == lastN else {
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
                   (try? child.localizedDescription()) == Self.notifyAnywayString {
                    return .dndCanNotify
                } else if (try? child.role()) == AXRole.staticText,
                          let hasNotificationsSilencedSuffix = Self.hasNotificationsSilencedSuffix,
                          (try? child.localizedDescription())?.hasSuffix(hasNotificationsSilencedSuffix) == true {
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

        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            guard let transcripts = try? transcriptsView,
                  let count = try? transcripts.children.count() else {
                throw ErrorMessage("transcriptsView not found")
            }
            guard let notifyAnywayButton = try? transcripts.children(range: (count - 2)..<count).first(where: {
                let child = try $0.children.value(at: 0)
                return (try? child.role()) == AXRole.button && (try? child.localizedDescription()) == Self.notifyAnywayString
            }) else {
                throw ErrorMessage("notify anyway not found")
            }
            try notifyAnywayButton.press()
        }
    }

    // TODO: Switch to os_unfair_lock if we drop old OSes, or maybe
    // determine the lock we use dynamically
    private let activityLock = NSLock()

    // called on run loop thread, not main node thread
    private func pollActivityStatus() {
        debugLog("pollActivityStatus")
        // if someone else (observe/removeObserver) holds the lock,
        // silently skip this polling attempt
        guard activityLock.try() else { return }
        defer { activityLock.unlock() }

        guard let observer = activityObserver else { return }

        guard self.isValid else {
            debugLog("pollActivityStatus: invalid MessagesController")
            return
        }

        guard (try? mainWindow.title()) == observer.windowTitle else {
            // debugLog("warning: Title changed. Not polling activity status.")
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

    func observe(address: String, callback: @escaping ([ActivityStatus]) -> Void) throws {
        let url = try MessagesDeepLink.addresses([address], body: nil).url()

        activityLock.lock()
        defer { activityLock.unlock() }

        // we remove the previous observer first, so that if
        // this method fails we don't keep sending notifs to the old
        // observer. We only update to the new observer once we've
        // successfully switched chats.
        try _removeObserver()

        let title = try withActivation(openBefore: nil, openAfter: url) {} ?? mainWindow.title()
        debugLog("Observing with title \(title)")

        activityObserver = .init(address: address, url: url, windowTitle: title, callback: callback)
    }

    private var isDisposed = false

    func dispose() {
        debugLog("Disposing MessagesController...")
        guard !isDisposed else { return }
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
