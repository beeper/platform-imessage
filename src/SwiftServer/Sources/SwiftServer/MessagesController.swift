import AppKit
import AccessibilityControl
import WindowControl
import Carbon.HIToolbox.Events

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
let isVenturaOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))

private enum LocalizedStrings {
    private static let chatKitFramework = Bundle(path: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework")!
    private static let chatKitFrameworkAxBundle = Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")!

    static let markAsRead = chatKitFramework.localizedString(forKey: "MARK_AS_READ", value: nil, table: "ChatKit")
    static let markAsUnread = chatKitFramework.localizedString(forKey: "MARK_AS_UNREAD", value: nil, table: "ChatKit")
    static let hasNotificationsSilencedSuffix = chatKitFramework.localizedString(forKey: "UNAVAILABILITY_INDICATOR_TITLE_FORMAT", value: nil, table: "ChatKit").replacingOccurrences(of: "%@", with: "")
    static let notifyAnyway = chatKitFramework.localizedString(forKey: "NOTIFY_ANYWAY_BUTTON_TITLE", value: nil, table: "ChatKit")

    static let replyTranscript = chatKitFrameworkAxBundle.localizedString(forKey: "group.reply.collection", value: nil, table: "Accessibility")

    static let showAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "show.alerts.collection.view.cell", value: nil, table: "Accessibility")
    static let hideAlerts = chatKitFrameworkAxBundle.localizedString(forKey: "hide.alerts.collection.view.cell", value: nil, table: "Accessibility")

    static let react = chatKitFrameworkAxBundle.localizedString(forKey: "acknowledgments.action.title", value: nil, table: "Accessibility")
    static let reply = chatKitFrameworkAxBundle.localizedString(forKey: "balloon.message.reply", value: nil, table: "Accessibility")

    static let delete = chatKitFrameworkAxBundle.localizedString(forKey: "delete.button.label", value: nil, table: "Accessibility")
}

private enum MessageAction {
    case react, reply

    var localized: String {
        switch self {
            case .react:
                return LocalizedStrings.react
            case .reply:
                return LocalizedStrings.reply
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

    private static let messagesBundleID = "com.apple.MobileSMS"

    private static let messagesUserDefaults = UserDefaults(suiteName: messagesBundleID)

    private static let pollingInterval: TimeInterval = 1

    private let app: NSRunningApplication
    private let appElement: Accessibility.Element

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
    private static func openDeepLink(_ url: URL, withoutActivation: Bool) throws -> NSRunningApplication {
        debugLog("Opening deep link: \(url) withoutActivation=\(withoutActivation)")
        return try NSWorkspace.shared.open(
            url,
            options: withoutActivation ? [.andHide, .withoutActivation] : [.andHide],
            configuration: [:]
        )
    }

    private static func getRunningMessagesApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID)
    }

    private static func resetPrompts() {
        // Self.messagesUserDefaults?.set(true, forKey: "kHasSetupHashtagImages") // unknown
        Self.messagesUserDefaults?.set(true, forKey: "SMSRelaySettingsConfirmed") // unknown
        Self.messagesUserDefaults?.set(true, forKey: "ReadReceiptSettingsConfirmed")
        Self.messagesUserDefaults?.set(2, forKey: "BusinessChatPrivacyPageDisplayed")
    }

    private func isPromptVisibleInMessagesApp() -> Bool {
        allWindows.contains(where: { (try? $0.windowCloseButton().isEnabled()) == false })
    }

    private static func getSelectedThreadID() -> String? {
        // CKLastSelectedItemIdentifier => "list-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => "pinned-iMessage;-;hi@kishan.info"
        // CKLastSelectedItemIdentifier => CKConversationListNewMessageCellIdentifier
        Self.messagesUserDefaults?.string(forKey: "CKLastSelectedItemIdentifier")?.split(separator: "-", maxSplits: 1).last.flatMap(String.init)
    }

    private static func isSelectedThreadCellPinned() -> Bool {
        Self.messagesUserDefaults?.string(forKey: "CKLastSelectedItemIdentifier")?.hasPrefix("pinned-") == true
    }

    // remember transparent thread merging (edge case #1 in readme.md)
    private static func ensureSelectedThread(threadID: String) throws {
        try retry(withTimeout: 1.5, interval: 0.05) {
            guard Self.getSelectedThreadID() == threadID else { throw ErrorMessage("thread not selected") }
        }
    }

    private static func ensureComposeCellSelected() throws {
        try retry(withTimeout: 1.5, interval: 0.05) {
            guard Self.messagesUserDefaults?.string(forKey: "CKLastSelectedItemIdentifier") == "CKConversationListNewMessageCellIdentifier" else { throw ErrorMessage("compose cell not selected") }
        }
    }

    private func selectedThreadCell() -> Accessibility.Element? {
        try? conversationsList.selectedChildren.value(at: 0)
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

        // without sleeping, appElement.observe applicationActivated/applicationDeactivated doesn't fire
        try app.waitForLaunch()
        appElement = Accessibility.Element(pid: app.processIdentifier)
        whm.setApp(app)
        whm.setAfterHide {
            self.getMainWindow().map { try? Self.resizeWindowToMaxHeight($0) }
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
            dispose() // since deinit isn't called when init throws
            throw ErrorMessage("Initialized MessagesController in an invalid state: appTerminated=\(app.isTerminated), mwFrameValid=\(Result { try mainWindow.isFrameValid }), whmValid=\(whm.isValid)")
        }
    }

    var isValid: Bool {
        !app.isTerminated && (try? mainWindow.isFrameValid) != nil && whm.isValid
    }

    private var allWindows: [Accessibility.Element] { // takes ~0ms
        get {
            // after a window is moved to the new space, AX doesn't list the window in appWindows or children
            (((try? appElement.appWindows()) ?? []) + [try? appElement.appMainWindow(), try? appElement.appFocusedWindow()]).compactMap { $0 }
        }
    }

    private func getMainWindow() -> Accessibility.Element? { // takes ~24ms
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("getMainWindow took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        return allWindows.first(where: {
            // note: don't detect presence of AXSplitter here, it's unreliable
            $0.recursivelyFindChild(withID: "ConversationList") != nil ||
                $0.recursivelyFindChild(withID: "CKConversationListCollectionView") != nil
        })
    }

    private func getComposeCell() -> Accessibility.Element? {
        try? conversationsList.children().first(where: Self.isThreadCellCompose)
    }

    private var cachedMainWindow: Accessibility.Element?
    // private var cachedConversationsList: Accessibility.Element?
    // private var cachedTranscriptView: Accessibility.Element?
    // private var cachedReplyTranscriptView: Accessibility.Element?

    // private func clearCachedElements() {
    //     // these are manually cleared because we aren't checking for validity on each property access
    //     // for cachedConversationsList, isValid/isFrameValid/isInViewport all return true even after the main window is closed
    //     cachedConversationsList = nil
    //     cachedTranscriptView = nil
    //     cachedReplyTranscriptView = nil
    // }

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
            // clearCachedElements()
            cachedMainWindow = mainWindow
            return mainWindow
        }
    }

    private var conversationsList: Accessibility.Element { // takes ~34ms
        get throws {
            // if let cached = cachedConversationsList {
            //     return cached
            // }
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("conversationsList took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            let cl = try retry(withTimeout: 1, interval: 0.1) {
                try mainWindow.recursivelyFindChild(withID: "ConversationList")
                    .orThrow(ErrorMessage("Could not find ConversationList"))
            } onError: { _, _ in
                let searchField = try self.searchField()
                debugLog("Getting ConversationList errored, calling searchField.cancel")
                // this will close the search results if active
                try searchField.cancel()
            }
            // cachedConversationsList = cl
            return cl
        }
    }

    // this return type was copied from compiler error
    private var mainWindowSections: LazyMapCollection<LazyFilterSequence<LazyMapSequence<LazySequence<[[String: CFTypeRef]]>.Elements, Accessibility.Element?>>, Accessibility.Element> {
        get throws {
            try mainWindow.sections().lazy.compactMap { $0["SectionObject"].flatMap { Accessibility.Element(erased: $0) } }
        }
    }

    private func messageAction(messageCell: Accessibility.Element, action: MessageAction) throws -> Accessibility.Action {
        // [press, AXScrollToVisible, show menu, Escape, scroll left by a page, scroll right by a page, React, Reply, Copy]
        // ["AXPress", "AXScrollToVisible", "AXShowMenu", "AXCancel", "AXScrollLeftByPage", "AXScrollRightByPage", "Name:React\nTarget:0x0\nSelector:(null)", "Name:Reply\nTarget:0x0\nSelector:(null)", "Name:Copy\nTarget:0x0\nSelector:(null)"]
        // non-AX actions are [React, Reply, Copy, Pin]
        // Pin is missing for non-links / Big Sur
        let allActions = try messageCell.supportedActions()
        guard let action = allActions.first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") }) else {
            throw ErrorMessage("Could not find \(action) action")
        }
        return action
    }

    private func reactButtons(messageCell: Accessibility.Element) throws -> [Accessibility.Element] {
        let reactAction = try messageAction(messageCell: messageCell, action: .react)
        try reactAction() // performing this 2x will close reaction view
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

    private func getTranscriptView(replyTranscript: Bool) throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("getTranscriptView took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        func isReplyTranscriptView(_ el: Accessibility.Element) -> Bool {
            // alternative: (localizedDescription == "Messages" when main transcript)
            (try? el.localizedDescription()) == LocalizedStrings.replyTranscript
            /*
              when it's replyTranscript/overlay=true, linkedElements.count == 1 (the sole linked element is messageBodyField),
              BUT only when it's not a compose cell
              so we are NOT using this: (try? el.linkedElements.count()) ?? 0 == 0
            */
        }
        let predicate = { (el: Accessibility.Element) -> Bool in
            (try? el.identifier()) == "TranscriptCollectionView" && isReplyTranscriptView(el) == replyTranscript
        }
        // takes ~8ms
        return try mainWindowSections.first(where: predicate)
        // takes ~19ms
        // return try mainWindow.recursiveChildren().lazy.first(where: predicate)
            .orThrow(ErrorMessage("Could not find TranscriptCollectionView, replyTranscript=\(replyTranscript)"))
    }

    private var transcriptView: Accessibility.Element {
        get throws {
            // if let cached = cachedTranscriptView, cached.isInViewport {
            //     return cached
            // }
            let tcv = try getTranscriptView(replyTranscript: false)
            // cachedTranscriptView = tcv
            return tcv
        }
    }

    private var replyTranscriptView: Accessibility.Element {
        get throws {
            // if let cached = cachedReplyTranscriptView, cached.isInViewport {
            //     return cached
            // }
            let tcv = try getTranscriptView(replyTranscript: true)
            // cachedReplyTranscriptView = tcv
            return tcv
        }
    }

    private func messagesField() throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("messagesField took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        return try retry(withTimeout: 1.5, interval: 0.2) {
            try mainWindow.recursivelyFindChild(withID: "messageBodyField")
                .orThrow(ErrorMessage("Could not find messageBodyField"))
        }
    }

    private func searchField() throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("searchField took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        return try retry(withTimeout: 1.5, interval: 0.2) {
            let CKConversationListCollectionView = try mainWindow.recursivelyFindChild(withID: "CKConversationListCollectionView")
                .orThrow(ErrorMessage("Could not find CKConversationListCollectionView"))
            return try CKConversationListCollectionView.children().first { (try? $0.subrole()) == AXRole.searchField }
                .orThrow(ErrorMessage("Could not find searchField"))
        }
    }

    private func reactionsView() throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("reactionsView took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        return try retry(withTimeout: 1.5, interval: 0.2) {
            guard let iOSContentGroup = try mainWindow.children().first(where: { (try? $0.role()) == AXRole.group && (try? $0.subrole()) == "iOSContentGroup" }),
                  // (try? iOSContentGroup.children.count()) ?? 0 >= 2,
                  let presView = try? iOSContentGroup.children.value(at: 0),
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

    // performs `perform` while the Messages window is unhidden
    private func withActivation(
        openBefore: URL?, openAfter: URL?,
        perform: () throws -> Void
    ) throws {
        if let openBefore = openBefore {
            try Self.openDeepLink(openBefore, withoutActivation: true)
        }

        try perform()

        if let openAfter = openAfter {
            if openAfter == openBefore {
                // debugLog("withActivation: skipping, openAfter == openBefore")
            } else {
                // debugLog("withActivation: returning to openAfter \(openAfter)")
                try Self.openDeepLink(openAfter, withoutActivation: true)
            }
        }
    }

    private static func isThreadCellCompose(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription()) == nil
    }

    private static func isMessageContainerCell(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription())?.isEmpty == false &&
            (try? el.children.value(at: 0).supportedActions().contains(where: { $0.name.value.hasPrefix("Name:\(LocalizedStrings.react)") })) == true
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

    private func withMessageCell(threadID: String, messageCell: MessageCell, action: (_ cell: Accessibility.Element) throws -> Void) throws {
        debugLog("withMessageCell \(messageCell)")

        let url = try MessagesDeepLink.message(guid: messageCell.messageGUID, overlay: messageCell.overlay).url()

        // without closing reply transcript, non-overlay deep link won't select the message
        if !messageCell.overlay, let rtv = try? replyTranscriptView {
            debugLog("calling replyTranscriptView.cancel()")
            try? rtv.cancel()
        }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try Self.ensureSelectedThread(threadID: threadID)

            // we don't close transcript view here because when reacting, closing it will undo the reaction
            // defer {
            //     if messageCell.overlay {
            //         // alt: try? sendKeyPress(key: CGKeyCode(kVK_Escape))
            //         Thread.sleep(forTimeInterval: 0.1)
            //         try? replyTranscriptView.cancel()
            //     }
            // }
            if messageCell.overlay { try waitUntilReplyTranscriptVisible() }
            guard let selected = (try retry(withTimeout: 1, interval: 0.2) { () -> Accessibility.Element? in
                guard let cell = try messageCell.overlay ? Self.firstMessageCell(in: replyTranscriptView) : Self.firstSelectedMessageCell(in: transcriptView) else {
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
                let containerCells = try Self.messageContainerCells(in: messageCell.overlay ? replyTranscriptView : transcriptView)
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
            let buttons = try reactButtons(messageCell: $0)

            let btn = buttons[idx]
            try retry(withTimeout: 1.2, interval: 0.2) {
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

    func removeComposeCell(_ composeCell: Accessibility.Element) throws {
        debugLog("removeComposeCell")
        let deleteAction = try composeCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(LocalizedStrings.delete)") })
            .orThrow(ErrorMessage("composeCell.deleteAction not found"))
        try deleteAction()
    }

    func toggleThreadRead(threadID: String, messageGUID: String, read: Bool) throws {
        let startTime = Date()
        defer { Logger.log("toggleThreadRead took \(startTime.timeIntervalSinceNow * -1000)ms") }

        let url = try MessagesDeepLink.message(guid: messageGUID, overlay: false).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try Self.ensureSelectedThread(threadID: threadID)
            let actionName = read ? LocalizedStrings.markAsRead : LocalizedStrings.markAsUnread
            do {
                let threadCell = try waitUntilSelectedThreadCell(isCompose: false).orThrow(ErrorMessage("Thread cell not found"))
                let action = try threadCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(actionName)") }).orThrow(ErrorMessage("mark\(read ? "Read" : "Unread")Action not found"))
                try action()
            } catch {
                if isVenturaOrUp { try sendCommandShiftUPress() }
                else { throw error }
            }
        }
    }

    func muteThread(threadID: String, muted: Bool) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try Self.ensureSelectedThread(threadID: threadID)
            let threadCell = try waitUntilSelectedThreadCell(isCompose: false).orThrow(ErrorMessage("Thread cell not found"))
            // at least on Monterey: for pinned thread cells, this should be
            // Self.isSelectedThreadCellPinned() ? LocalizedStrings.hideAlerts : LocalizedStrings.hideAlerts + ", On"
            let name = muted || Self.isSelectedThreadCellPinned() ? LocalizedStrings.hideAlerts : LocalizedStrings.showAlerts
            let muteAction = try threadCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(name)") }).orThrow(ErrorMessage("muteAction not found"))
            try muteAction()
        }
    }

    func deleteThread(threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()

        whm.hide()
        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try Self.ensureSelectedThread(threadID: threadID)
            let threadCell = try waitUntilSelectedThreadCell(isCompose: false).orThrow(ErrorMessage("Thread cell not found"))
            let deleteAction = try threadCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(LocalizedStrings.delete)") }).orThrow(ErrorMessage("deleteAction not found"))
            try deleteAction()
            let alertSheet = try mainWindow.children().first(where: { try $0.role() == AXRole.sheet }).orThrow(ErrorMessage("alertSheet not found"))
            let deleteButton = try alertSheet.children().first(where: { try $0.role() == AXRole.button }).orThrow(ErrorMessage("deleteButton not found"))
            try deleteButton.press()
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

            try Self.ensureSelectedThread(threadID: threadID)

            try messagesField().value(assign: "")
        }
    }

    private func sendKeyPress(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        debugLog("sendKey key=\(key)")
        for keyDown in [true, false] {
            debugLog("Sending key \(key) \(keyDown ? "down" : "up")")
            let ev = try CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("Could not send key \(key)"))
            if let flags = flags { ev.flags = flags }
            ev.postToPid(app.processIdentifier)
        }
    }
    private func sendReturnPress() throws {
        try runOnMainThread {
            try sendKeyPress(key: CGKeyCode(kVK_Return))
        }
    }
    private func sendCommandVPress() throws {
        try runOnMainThread {
            // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
            guard let keyCode = KeyMap.shared["v"] else { return }
            try sendKeyPress(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    private func sendCommandShiftUPress() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["u"] else { return }
            try sendKeyPress(key: CGKeyCode(keyCode), flags: .maskCommand.union(.maskShift))
        }
    }

    private func focusMessageField(_ messageField: Accessibility.Element) throws {
        try retry(withTimeout: 1, interval: 0.2) {
            // this doesn't ever focus in compose thread for some reason
            try messageField.isFocused(assign: true)
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
        try focusMessageField(messageField) // focus is partially redundant, hitting enter without focus works too unless another text field is focused
        try self.sendReturnPress()
        try retry(withTimeout: 1.5, interval: 0.2) {
            if let message = try? messageFieldValue(messageField), !message.isEmpty {
                let hasNewline = message.hasSuffix("\n")
                throw ErrorMessage("Could not send message\(hasNewline ? " (extraneous newline)" : "")")
            }
        } onError: { attempt, _  in
            if attempt == 5 { // penultimate attempt
                // try? self.sendReturnPress()
            }
        }
    }

    private func closeReplyTranscriptView() {
        guard let rtv = try? replyTranscriptView else { return }
        debugLog("calling replyTranscriptView.cancel()")
        try? rtv.cancel()
        Thread.sleep(forTimeInterval: 0.2) // wait for animation, todo use better logic
    }

    private func waitUntilReplyTranscriptVisible() throws {
        debugLog("waitUntilReplyTranscriptVisible")
        try retry(withTimeout: 1.5, interval: 0.1) {
            if (try? replyTranscriptView.isInViewport) != true {
                throw ErrorMessage("Could not find replyTranscriptView")
            }
        }
    }

    private func sendReplyWithoutOverlay(threadID: String, quotedMessage: MessageCell, text: String?, filePath: String?) throws {
        try withMessageCell(threadID: threadID, messageCell: quotedMessage) {
            let replyAction = try messageAction(messageCell: $0, action: .reply)
            try replyAction()
            let messageField = try messagesField()
            if let text = text {
                try assignToMessageField(messageField, text: text)
            } else if let filePath = filePath {
                try self.pasteFileInBodyField(messageField, filePath: filePath)
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

        if quotedMessage == nil { self.closeReplyTranscriptView() } // needed even when opening deep link

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            if let threadID = threadID { try Self.ensureSelectedThread(threadID: threadID) }

            if quotedMessage != nil {
                try waitUntilReplyTranscriptVisible()
            }
            if let text = text {
                if let selected = selectedThreadCell(), Self.isThreadCellCompose(selected) {
                    // since this is a new thread not in contacts, it may take a while for messages app to resolve that the address is imessage and not just sms
                    debugLog("waiting 1.5s for address to resolve")
                    Thread.sleep(forTimeInterval: 1.5)
                }

                let messageField = try messagesField()
                if quotedMessage != nil { // text has to be manually assigned when quoted since ?body in deep link doesn't take any effect
                    try assignToMessageField(messageField, text: text)
                }
                try sendMessageInField(messageField)
            } else if let filePath = filePath {
                let messageField = try messagesField()
                try self.pasteFileInBodyField(messageField, filePath: filePath)
                try sendMessageInField(messageField)
            }
        }
    }

    #if DEBUG
    func closeAllWindows() throws {
        try mainWindow.closeWindow()
        try appElement.appWindows().forEach { try $0.closeWindow() }
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
        try? messageField.value(assign: "")
        try focusMessageField(messageField) // focus is partially redundant, hitting ⌘ V without focus works too unless another text field is focused
        let pasteboard = NSPasteboard.general
        try pasteboard.withRestoration {
            pasteboard.setString(fileURL.relativeString, forType: .fileURL)
            try self.sendCommandVPress()
            try retry(withTimeout: 2, interval: 0.1) {
                // 2 for <OBJ_REPLACEMENT_CHAR> and \n
                let charCountResult = Result { try messageField.noOfChars() }
                guard case let .success(charCount) = charCountResult, charCount == 2 else {
                    throw ErrorMessage("file was not pasted. \(charCountResult)")
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
            let window = getMainWindow()
            try whm.appActivated(window: window)
            if window != nil, !Preferences.enabledExperiments.isEmpty  {
                if let composeCell = getComposeCell() {
                    try? removeComposeCell(composeCell)
                }
            }
        } catch {
            debugLog("warning: Could not show Messages window: \(error)")
        }
    }

    private func deactivateMessages() {
        do {
            debugLog("deactivateMessages")
            // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
            try whm.appDeactivated(window: getMainWindow())
        } catch {
            debugLog("warning: Could not hide Messages window: \(error)")
        }
    }

    private func activityStatus() -> [ActivityStatus] {
        guard let transcript = try? transcriptView,
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
            try Self.ensureSelectedThread(threadID: threadID)

            guard let transcript = try? transcriptView,
                  let count = try? transcript.children.count() else {
                throw ErrorMessage("transcriptView not found")
            }
            guard let notifyAnywayButton = try? transcript.children(range: (count - 2)..<count).first(where: {
                let child = try $0.children.value(at: 0)
                return (try? child.role()) == AXRole.button && (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway
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
        guard let observer = activityObserver else { return }
        // if someone else (observe/removeObserver) holds the lock,
        // silently skip this polling attempt
        guard activityLock.try() else { return }
        defer { activityLock.unlock() }

        debugLog("pollActivityStatus")

        guard self.isValid else {
            debugLog("pollActivityStatus: invalid MessagesController")
            return
        }

        let currentThreadID = Self.getSelectedThreadID()
        guard currentThreadID == observer.threadID else {
            debugLog("pollActivityStatus: selected thread changed, not polling \(currentThreadID ?? "nil") \(observer.threadID)")
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

        try Self.openDeepLink(url, withoutActivation: true)
        activityObserver = .init(threadID: threadID, url: url, callback: callback)
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
