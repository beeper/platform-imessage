import Foundation
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

// will be optimized out in release mode
@_transparent
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard SwiftServer.isLoggingEnabled else { return }
    print(message())
    #endif
}

extension Accessibility.Notification {
    static let layoutChanged = Self(kAXLayoutChangedNotification)
    static let applicationActivated = Self(kAXApplicationActivatedNotification)
    static let applicationDeactivated = Self(kAXApplicationDeactivatedNotification)
}

// refer to AXAttributeConstants.h
// https://gist.github.com/p6p/24fbac5d12891fcfffa2b53761f4343e
// https://developer.apple.com/documentation/applicationservices/axattributeconstants_h/miscellaneous_defines
extension Accessibility.Names {
    var children: AttributeName<[Accessibility.Element]> { .init(kAXChildrenAttribute) }
    var selectedChildren: AttributeName<[Accessibility.Element]> { .init(kAXSelectedChildrenAttribute) }
    var linkedElements: AttributeName<[Accessibility.Element]> { .init(kAXLinkedUIElementsAttribute) }
    var parent: AttributeName<Accessibility.Element> { .init(kAXParentAttribute) }

    // this wont work without the com.apple.private.accessibility.inspection entitlement
    // https://stackoverflow.com/questions/45590888/how-to-get-the-objective-c-class-name-corresponding-to-an-axuielement
    var className: AttributeName<String> { "AXClassName" }

    var minValue: AttributeName<Any> { .init(kAXMinValueAttribute) }
    var maxValue: AttributeName<Any> { .init(kAXMaxValueAttribute) }
    var value: MutableAttributeName<Any> { .init(kAXValueAttribute) }

    var position: MutableAttributeName<CGPoint> { .init(kAXPositionAttribute) }
    var size: MutableAttributeName<CGSize> { .init(kAXSizeAttribute) }
    var frame: AttributeName<CGRect> { "AXFrame" }

    var title: AttributeName<String> { .init(kAXTitleAttribute) }
    var localizedDescription: AttributeName<String> { .init(kAXDescriptionAttribute) }
    var identifier: AttributeName<String> { .init(kAXIdentifierAttribute) }
    var role: AttributeName<String> { .init(kAXRoleAttribute) }
    var subrole: AttributeName<String> { .init(kAXSubroleAttribute) }
    var roleDescription: AttributeName<String> { .init(kAXRoleDescriptionAttribute) }

    var isSelected: AttributeName<Bool> { .init(kAXSelectedAttribute) }
    var isFocused: MutableAttributeName<Bool> { .init(kAXFocusedAttribute) }

    // https://developer.apple.com/documentation/applicationservices/axactionconstants_h/miscellaneous_defines
    var press: ActionName { .init(kAXPressAction) }
    var cancel: ActionName { .init(kAXCancelAction) }
    #if DEBUG
    var showMenu: ActionName { .init(kAXShowMenuAction) }
    #endif

    // App-specific
    var appWindows: AttributeName<[Accessibility.Element]> { .init(kAXWindowsAttribute) }
    var appMainWindow: AttributeName<Accessibility.Element> { .init(kAXMainWindowAttribute) }
    var appFocusedWindow: AttributeName<Accessibility.Element> { .init(kAXFocusedWindowAttribute) }

    // Window-specific
    var windowIsMinimized: MutableAttributeName<Bool> { .init(kAXMinimizedAttribute) }
    var windowIsFullScreen: MutableAttributeName<Bool> { "AXFullScreen" }
    var windowCloseButton: AttributeName<Accessibility.Element> { .init(kAXCloseButtonAttribute) }
}

extension Accessibility.Element {
    var isValid: Bool {
        (try? pid()) != nil
    }

    var isInViewport: Bool {
        (try? self.frame()) != CGRect.null
    }

    // breadth-first, seems faster than dfs
    func recursiveChildren() -> AnySequence<Accessibility.Element> {
        AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            let elt = queue.removeFirst()
            if let children = try? elt.children() {
                queue.append(contentsOf: children)
            }
            return elt
        })
    }

    func recursiveSelectedChildren() -> AnySequence<Accessibility.Element> {
        AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            let elt = queue.removeFirst()
            if let selectedChildren = try? elt.selectedChildren() {
                queue.append(contentsOf: selectedChildren)
            }
            return elt
        })
    }

    func child(withID id: String) -> Accessibility.Element? {
        recursiveChildren().lazy.first {
            (try? $0.identifier()) == id
        }
    }

    func setFrame(_ frame: CGRect) throws {
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            switch i {
            case 0:
                try? self.position(assign: frame.origin)
            case 1:
                try? self.size(assign: frame.size)
            default:
                break
            }
        }
    }
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

let IS_MONTEREY_OR_UP = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12

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
    private static var hasNotificationsSilencedSuffix: String? {
        guard IS_MONTEREY_OR_UP, let bundle = Bundle(path: "/System/Library/PrivateFrameworks/FocusSettingsUI.framework") else {
            return nil
        }
        return bundle.localizedString(forKey: "AVAILABILITY_STATUS_EXAMPLE_%@", value: nil, table: nil).replacingOccurrences(of: "%@", with: "")
    }

    private static let pollingInterval: TimeInterval = 1

    private var lastActiveDisplay: Display
    private let space: Space
    private let app: NSRunningApplication
    private let appElement: Accessibility.Element
    private let mainWindow: Accessibility.Element

    private let phtConn: PHTConnection?

    private var timer: Timer?
    private var loopThread: RunLoopThread?

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?

    private var activityObserver: ActivityObserver?

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

    // returns last active display
    private static func moveWindow(_ window: Accessibility.Element, to space: Space) throws -> Display {
        try? Self.resizeWindowToMaxHeight(window)
        #if NO_SPACES
        return .main
        #else
        let windowCG = try window.window()

        // FIXME: this doesn't seem to work consistently with multiple displays
        let lastActiveDisplay: Display
        if let lastActiveSpace = try? windowCG.currentSpaces(.allVisibleSpaces).first,
           let activeDisplay = try? Display.allOnline().first(where: { (try? $0.currentSpace()) == lastActiveSpace }) {
            lastActiveDisplay = activeDisplay
        } else {
            lastActiveDisplay = .main
        }
        try windowCG.moveToSpace(space)
        return lastActiveDisplay
        #endif
    }

    private static func retry<T>(
        withTimeout timeout: TimeInterval,
        interval: TimeInterval? = nil,
        _ perform: () throws -> T,
        onError: ((_ attempt: Int, _ err: Error?) throws -> Void)? = nil
    ) throws -> T {
        let start = Date()
        var res: Result<T, Error>
        var attempt = 0
        repeat {
            res = Result(catching: perform)
            switch res {
            case let .success(val):
                return val
            case let .failure(err):
                do {
                    try onError?(attempt, err)
                    attempt += 1
                } catch {
                    debugLog("retry onError errored \(error)")
                }
            }
            interval.map(Thread.sleep(forTimeInterval:))
        } while -start.timeIntervalSinceNow < timeout
        return try res.get()
    }

    @discardableResult
    private static func openDeepLink(_ url: URL, withoutActivation: Bool) throws -> NSRunningApplication {
        try NSWorkspace.shared.open(
            url,
            options: withoutActivation ? [.andHide, .withoutActivation] : [.andHide],
            configuration: [:]
        )
    }

    init() throws {
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Texts does not have Accessibility permissions")
        }

        func getAppWindowsClosingInaccessibleWindows(_ appEl: Accessibility.Element) -> [Accessibility.Element] {
            if let windows = try? appEl.appWindows() {
                // after a window is moved to the new space, AX doesn't list the window in appWindows or children
                if windows.isEmpty {
                    if let win = try? appEl.appMainWindow() {
                        debugLog("appWindows empty, closing app main window")
                        try? Self.closeWindow(win)
                    } else if let win = try? appEl.appFocusedWindow() {
                        debugLog("appWindows empty, closing focused main window")
                        try? Self.closeWindow(win)
                    }
                }
                return windows
            }
            return []
        }

        var reusableApp: NSRunningApplication?
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID).first {
            let appEl = Accessibility.Element(pid: running.processIdentifier)
            let knownSpaces = Set((try? Space.list()) ?? [])
            let windows = getAppWindowsClosingInaccessibleWindows(appEl)
            if !knownSpaces.isEmpty,
               // iff each Messages window exists in visible spaces and visible spaces only
               let spaces = try? windows.map({ try $0.window().currentSpaces() }),
               spaces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(knownSpaces.contains) }) {
                reusableApp = running
            } else {
                debugLog("Terminating existing Messages...")
                if running.terminate() {
                    try? Self.retry(withTimeout: 1, interval: 0.1) {
                        guard running.isTerminated else {
                            throw ErrorMessage("Could not restart Messages")
                        }
                    }
                }
            }
        }

        if let reusableApp = reusableApp {
            debugLog("Reusing existing Messages...")
            app = reusableApp
        } else {
            debugLog("Launching Messages...")
            app = try Self.openDeepLink(MessagesDeepLink.compose.url(), withoutActivation: true)
        }
        appElement = Accessibility.Element(pid: app.processIdentifier)

        if SwiftServer.isPHTEnabled {
            let phtConn = try PHTConnection.create(allowInstall: true)
            try phtConn.setMessagesHidden(true)
            self.phtConn = phtConn
        } else {
            self.phtConn = nil
        }

        let getMainWindow = { [appElement] () throws -> Accessibility.Element in
            try appElement.appWindows().first(where: {
                // note: don't detect presence of AXSplitter here, it's unreliable
                $0.child(withID: "ConversationList") != nil ||
                    $0.child(withID: "CKConversationListCollectionView") != nil
            })
            .orThrow(ErrorMessage("Could not get main Messages window"))
        }
        self.mainWindow = try Self.retry(withTimeout: 5, interval: 0.2, getMainWindow, onError: { attempt, _ in
            if attempt == 0 {
                try Self.openDeepLink(MessagesDeepLink.compose.url(), withoutActivation: true)
            }
        })

        space = try Space(newSpaceOfKind: .fullscreen)
        lastActiveDisplay = try Self.moveWindow(mainWindow, to: space)

        // if app.isHidden {
        //     debugLog("Unhiding Messages...")
        //     try Self.retry(withTimeout: 1, interval: 0.1) { [app] in
        //         app.unhide()
        //         if app.isHidden {
        //             throw ErrorMessage("Could not launch Messages")
        //         }
        //     }
        // }

        #if DEBUG
        let existing = try Space.list()
        debugLog("[debug] \(existing.count) space(s)")
        existing.forEach {
            debugLog("[debug] * Name: \((try? $0.name()) as Any)")
            debugLog("[debug] * Kind: \((try? $0.kind()) as Any)")
            debugLog("[debug] * Owners: \((try? $0.owners()) ?? [])")
        }
        // existing.filter { (try? $0.name()) == "1FBF2F7F-57EC-56E5-521F-556A305D1A61" }.forEach {
        //     $0.destroy()
        // }
        #endif

        // we need a run loop for polling (and for any future AX observers), but Node
        // doesn't offer us one (since it uses its own uv loop which is incompatible
        // with NS/CFRunLoop). Therefore we create a background thread with a run loop.
        // Note that doing so on a dispatch queue would be very inefficient and so we
        // create our own thread for it; see https://stackoverflow.com/a/38001438/3769927 and
        // https://forums.swift.org/t/runloop-main-or-dispatchqueue-main-when-using-combine-scheduler/26635/4
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
        !app.isTerminated
            && (try? mainWindow.frame()) != nil
    }

    private func selectedThreadCell() -> Accessibility.Element? {
        try? conversationsList.selectedChildren.value(at: 0)
    }

    private var cachedConversationsList: Accessibility.Element?
    private var conversationsList: Accessibility.Element {
        get throws {
            if let cached = cachedConversationsList, cached.isValid {
                return cached
            }
            let cl = try Self.retry(withTimeout: 1, interval: 0.2) {
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

    private var cachedTranscriptsView: Accessibility.Element?
    private var transcriptsView: Accessibility.Element {
        get throws {
            if let cached = cachedTranscriptsView, cached.isValid, cached.isInViewport {
                return cached
            }
            let tcv = try getTranscriptsView(replyTranscripts: false)
            cachedTranscriptsView = tcv
            return tcv
        }
    }
    private var cachedReplyTranscriptsView: Accessibility.Element?
    private var replyTranscriptsView: Accessibility.Element {
        get throws {
            if let cached = cachedReplyTranscriptsView, cached.isValid, cached.isInViewport {
                return cached
            }
            let tcv = try getTranscriptsView(replyTranscripts: true)
            cachedReplyTranscriptsView = tcv
            return tcv
        }
    }

    private func messagesField() throws -> Accessibility.Element {
        try Self.retry(withTimeout: 1.5, interval: 0.25) {
            try mainWindow.child(withID: "messageBodyField")
                .orThrow(ErrorMessage("Could not find messageBodyField"))
        }
    }

    private func searchField() throws -> Accessibility.Element {
        try Self.retry(withTimeout: 1.5, interval: 0.25) {
            let CKConversationListCollectionView = try mainWindow.child(withID: "CKConversationListCollectionView")
                .orThrow(ErrorMessage("Could not find CKConversationListCollectionView"))
            return try CKConversationListCollectionView.children().first { (try? $0.subrole()) == AXRole.searchField }
                .orThrow(ErrorMessage("Could not find searchField"))
        }
    }

    private func reactionsView() throws -> Accessibility.Element {
        try Self.retry(withTimeout: 1.5, interval: 0.25) {
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
        try? Self.retry(withTimeout: timeout) { () throws -> Accessibility.Element in
            guard let selected = selectedThreadCell() else { throw ErrorMessage("") }
            let desc = try? selected.localizedDescription()
            let isActuallyCompose = desc == nil
            guard isCompose == isActuallyCompose else { throw ErrorMessage("") }
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
            newTitle = try? Self.retry(withTimeout: 1, interval: 0.1) {
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

    private func withMessageCell(guid: String, offset: Int, overlay: Bool, action: (_ cell: Accessibility.Element) throws -> Void) throws {
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
            guard let selected = (try Self.retry(withTimeout: 1, interval: 0.2) { () -> Accessibility.Element? in
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
            try action(targetCell)
        }
    }

    func setReaction(guid: String, offset: Int, reaction: Reaction, on: Bool, overlay: Bool) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        let idx = reaction.index
        try withMessageCell(guid: guid, offset: offset, overlay: overlay) { targetCell in
            let buttons = try reactButtons(targetCell: targetCell, overlay: overlay)

            let btn = buttons[idx]
            try Self.retry(withTimeout: 1, interval: 0.2) {
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
            guard let group = (try Self.retry(withTimeout: 1, interval: 0.1) { try mainWindow.children().first(where: { try $0.role() == AXRole.group }) }) else {
                throw ErrorMessage("Could not find main view")
            }
            guard let menu = (try Self.retry(withTimeout: 4, interval: 0.5) { try group.children().first(where: { try $0.role() == AXRole.menu }) }) else {
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

            try? Self.retry(withTimeout: 1, interval: 0.2) {
                guard try mainWindow.title() != initialTitle else {
                    throw ErrorMessage("")
                }
            }

            try messagesField().value(assign: "")
        }
    }

    private func sendKeyPress(key: CGKeyCode) throws {
        for keyDown in [true, false] {
            debugLog("Sending key \(key) \(keyDown ? "down" : "up")")
            try CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("Could not send key \(key)"))
                .postToPid(app.processIdentifier)
        }
    }

    private func sendReturnPress() throws {
        func _sendReturnKey() throws {
            try sendKeyPress(key: CGKeyCode(kVK_Return))
        }
        func sendReturnKey() throws {
            debugLog("sendReturnKey Thread.isMainThread=\(Thread.isMainThread) queueName=\(__dispatch_queue_get_label(nil))")
            if Thread.isMainThread {
                try _sendReturnKey()
            } else {
                try DispatchQueue.main.sync { try _sendReturnKey() }
            }
        }
        try sendReturnKey()
    }

    private func focusMessageField(_ messageField: Accessibility.Element) throws {
        try Self.retry(withTimeout: 1, interval: 0.25) {
            try messageField.isFocused(assign: true)
            guard try messageField.isFocused() else {
                throw ErrorMessage("Could not focus message text field")
            }
        }
    }

    private func waitUntilMessageFieldEmpty(_ messageField: Accessibility.Element) throws {
        try Self.retry(withTimeout: 1.5, interval: 0.25) {
            if let message = try? messageField.value() as? String, !message.isEmpty {
                let hasNewline = message.hasSuffix("\n")
                throw ErrorMessage("Could not send text message\(hasNewline ? " (extraneous newline)" : "")")
            }
        }
    }

    // the URL should be a deep link that fills the text field with the required message
    // (in the appropriate thread)
    private func sendTextMessage(url: URL) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        let initialTitle = try? mainWindow.title()

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            try? Self.retry(withTimeout: 1, interval: 0.2) {
                guard try mainWindow.title() != initialTitle else {
                    throw ErrorMessage("")
                }
            }

            let messageField = try messagesField()
            try focusMessageField(messageField)
            Thread.sleep(forTimeInterval: 0.1)
            try self.sendReturnPress()
            try waitUntilMessageFieldEmpty(messageField)
        }
    }

    func sendTextMessage(_ text: String, threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: text).url()
        try sendTextMessage(url: url)
    }

    func createThread(addresses: [String], message: String) throws {
        let url = try MessagesDeepLink.addresses(addresses, body: message).url()
        try sendTextMessage(url: url)
    }

    func sendReply(guid: String, text: String, overlay: Bool) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        func send() throws {
            let messageField = try messagesField()
            try messageField.value(assign: text)
            try focusMessageField(messageField)
            Thread.sleep(forTimeInterval: 0.1)
            try self.sendReturnPress()
            try waitUntilMessageFieldEmpty(messageField)
        }

        if overlay {
            let url = try MessagesDeepLink.message(guid: guid, overlay: overlay).url()
            try Self.openDeepLink(url, withoutActivation: true)
            Thread.sleep(forTimeInterval: 0.1)
            try send()
            return
        }

        try withMessageCell(guid: guid, offset: 0, overlay: overlay) { targetCell in
            let replyAction = try messageAction(targetCell: targetCell, name: "Reply", overlay: overlay)
            try replyAction()
            try send()
        }
    }

    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        do {
            try mainWindow.window().moveToSpace(lastActiveDisplay.currentSpace())
            try phtConn?.setMessagesHidden(false)
        } catch {
            debugLog("warning: Could not show Messages window: \(error)")
        }
    }

    private func deactivateMessages() {
        do {
            lastActiveDisplay = try Self.moveWindow(mainWindow, to: space)
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
            let lastN = IS_MONTEREY_OR_UP ? 3 : 2
            guard let elts = try? transcripts.children(range: (count - lastN)..<count), elts.count == lastN else {
                return [.unknown]
            }
            cellsToCheck = elts
        }
        // AXStaticText, localizedDescription="￼ Steve has notifications silenced"
        // AXButton, localizedDescription="Notify Anyway"
        let isDND = IS_MONTEREY_OR_UP && cellsToCheck.contains { elt in
            if (try? elt.children.count()) == 1,
               let child = try? elt.children.value(at: 0),
               (try? child.role()) == AXRole.staticText,
               let hasNotificationsSilencedSuffix = Self.hasNotificationsSilencedSuffix,
               (try? child.localizedDescription())?.hasSuffix(hasNotificationsSilencedSuffix) == true {
                return true
            }
            return false
        }
        let isTyping = cellsToCheck.contains { elt in
            // children can briefly be 0 for newly sent messages as well, so
            // that by itself isn't a good enough heuristic
            (try? elt.children.count()) == 0 && (try? elt.roleDescription().isEmpty) != false
        }
        let flags: [ActivityStatus] = (isTyping ? [.typing] : [.notTyping]) + (isDND ? [.dnd] : [])
        return flags
    }

    // TODO: Switch to os_unfair_lock if we drop old OSes, or maybe
    // determine the lock we use dynamically
    private let activityLock = NSLock()

    // called on run loop thread, not main node thread
    private func pollActivityStatus() {
        // if someone else (observe/removeObserver) holds the lock,
        // silently skip this polling attempt
        guard activityLock.try() else { return }
        defer { activityLock.unlock() }

        guard let observer = activityObserver else { return }

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
    }

    deinit {
        debugLog("deinit")
        dispose()
    }
}
