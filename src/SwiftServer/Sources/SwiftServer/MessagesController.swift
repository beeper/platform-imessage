import Foundation
import AppKit
import AccessibilityControl
import WindowControl

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { message }
}

// don't do globals, kids
var gIsLoggingEnabled = false

// will be optimized out in release mode
@_transparent
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard gIsLoggingEnabled else { return }
    print(message())
    #endif
}

extension Accessibility.Notification {
    static let layoutChanged = Self(kAXLayoutChangedNotification)
    static let applicationActivated = Self(kAXApplicationActivatedNotification)
    static let applicationDeactivated = Self(kAXApplicationDeactivatedNotification)
}

extension Accessibility.Names {
    var children: AttributeName<[Accessibility.Element]> { .init(kAXChildrenAttribute) }
    var appMainWindow: AttributeName<Accessibility.Element> { .init(kAXMainWindowAttribute) }
    var parent: AttributeName<Accessibility.Element> { .init(kAXParentAttribute) }

    var minValue: AttributeName<Any> { .init(kAXMinValueAttribute) }
    var maxValue: AttributeName<Any> { .init(kAXMaxValueAttribute) }
    var value: MutableAttributeName<Any> { .init(kAXValueAttribute) }

    var position: MutableAttributeName<CGPoint> { .init(kAXPositionAttribute) }
    var size: MutableAttributeName<CGSize> { .init(kAXSizeAttribute) }
    var frame: AttributeName<CGRect> { "AXFrame" }
    var windowTitle: AttributeName<String> { .init(kAXTitleAttribute) }

    var localizedDescription: AttributeName<String> { .init(kAXDescriptionAttribute) }
    var identifier: AttributeName<String> { .init(kAXIdentifierAttribute) }
    var role: AttributeName<String> { .init(kAXRoleAttribute) }
    var roleDescription: AttributeName<String> { .init(kAXRoleDescriptionAttribute) }

    var isSelected: AttributeName<Bool> { .init(kAXSelectedAttribute) }
    var isMinimized: MutableAttributeName<Bool> { .init(kAXMinimizedAttribute) }
    var isFullScreen: MutableAttributeName<Bool> { "AXFullScreen" }

    var press: ActionName { .init(kAXPressAction) }
}

extension Accessibility.Element {
    var isValid: Bool {
        (try? pid()) != nil
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

    func child(withID id: String) -> Accessibility.Element? {
        recursiveChildren().lazy.first {
            (try? $0.identifier()) == id
        }
    }

    func printAttributes() {
        for act in (try? supportedActions()) ?? [] {
            debugLog("[action] \(act.name): \(act.description)")
        }
        for att in (try? supportedAttributes()) ?? [] {
            debugLog("[regular] \(att.name): \((try? att()) as Any)")
        }
        for att in (try? supportedParameterizedAttributes()) ?? [] {
            debugLog("[parameterized] \(att)")
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
        case typing = "TYPING"
        case notTyping = "NOT_TYPING"
        case unknown = "UNKNOWN"
    }

    private class ActivityObserver {
        let address: String
        let url: URL
        let windowTitle: String

        // may be called on a bg thread
        private let callback: (ActivityStatus) -> Void

        private var lastSentTyping = false
        private var lastSentTime = Date()

        init(address: String, url: URL, windowTitle: String, callback: @escaping (ActivityStatus) -> Void) {
            self.address = address
            self.url = url
            self.windowTitle = windowTitle
            self.callback = callback
        }

        func send(_ status: ActivityStatus) {
            let sendTyping = status == .typing
            // send if the status is different OR if we're sending typing events and it's
            // been a long time since the last one
            guard lastSentTyping != sendTyping || (sendTyping && lastSentTime.timeIntervalSinceNow > 30) else {
                return
            }
            lastSentTyping = sendTyping
            lastSentTime = Date()
            callback(status)
        }
    }

    static let queue = DispatchQueue(label: "swift-server-queue")

    private static let messagesBundleID = "com.apple.MobileSMS"
    private static let messagesBundle = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: messagesBundleID
    )!

    private static let pollingInterval: TimeInterval = 1

    private var lastActiveDisplay: Display
    private let space: Space
    private let app: NSRunningApplication
    private let appElement: Accessibility.Element
    private let mainWindow: Accessibility.Element
    private let conversations: Accessibility.Element

    private var timer: Timer?
    private var loopThread: RunLoopThread?

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?

    private var activityObserver: ActivityObserver?

    // returns last active display
    private static func moveWindow(_ window: Accessibility.Element, to space: Space) throws -> Display {
        let windowCG = try window.window()

        // FIXME: this doesn't seem to work consistently
        let lastActiveDisplay: Display
        if let lastActiveSpace = try? windowCG.currentSpaces(.allVisibleSpaces).first,
           let activeDisplay = try? Display.allOnline().first(where: { try $0.currentSpace() == lastActiveSpace }) {
            lastActiveDisplay = activeDisplay
        } else {
            lastActiveDisplay = .main
        }
        try windowCG.moveToSpace(space)
        return lastActiveDisplay
    }

    private static func retry<T>(
        withTimeout timeout: TimeInterval,
        interval: TimeInterval? = nil,
        _ perform: () throws -> T
    ) throws -> T {
        let start = Date()
        var res: Result<T, Error>
        repeat {
            res = Result(catching: perform)
            if case let .success(val) = res {
                return val
            }
            interval.map(Thread.sleep(forTimeInterval:))
        } while -start.timeIntervalSinceNow < timeout
        return try res.get()
    }

    init() throws {
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Texts does not have Accessibility permissions")
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID).first {
            debugLog("Terminating existing Messages...")
            if running.terminate() {
                try? Self.retry(withTimeout: 1, interval: 0.1) {
                    guard running.isTerminated else {
                        throw ErrorMessage("Could not restart Messages")
                    }
                }
            }
        }

        debugLog("Launching Messages...")
        app = try NSWorkspace.shared.launchApplication(at: Self.messagesBundle, options: [.andHide], configuration: [:])
        appElement = Accessibility.Element(pid: app.processIdentifier)

        let getMainWindow = { [appElement] () throws -> Accessibility.Element in
            guard let child = try? appElement.children().first(
                where: { (try? $0.identifier()) == "SceneWindow" }
            ) else {
                throw ErrorMessage("Could not get main Messages window")
            }
            return child
        }

        self.mainWindow = try Self.retry(withTimeout: 10, interval: 0.1, getMainWindow)

        space = try Space(newSpaceOfKind: .fullscreen)
        lastActiveDisplay = try Self.moveWindow(mainWindow, to: space)

        let existing = try Space.list(.allSpaces)
        debugLog("Number of spaces: \(existing.count)")
        existing.forEach {
            debugLog("Name: \((try? $0.name()) as Any)")
            debugLog("Kind: \((try? $0.kind()) as Any)")
            debugLog("Owners: \((try? $0.owners()) ?? [])")
        }
//        existing.filter { (try? $0.name()) == "1FBF2F7F-57EC-56E5-521F-556A305D1A61" }.forEach {
//            $0.destroy()
//        }

        guard let conversations = mainWindow.child(withID: "ConversationList") else {
            throw ErrorMessage("Could not get Messages conversation list")
        }
        self.conversations = conversations

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

        #if false
        // FIXME: don't move if already visible
        try setWindowFrame(CGRect(x: 500, y: 25, width: 700, height: 300))
        #endif

        guard self.isValid else {
            throw ErrorMessage("Initialized MessagesController in an invalid state")
        }
    }

    var isValid: Bool {
        !app.isTerminated
            && (try? mainWindow.frame()) != nil
            && conversations.isValid
    }

    private func selectedCell() -> Accessibility.Element? {
        try? conversations.children().first {
            (try? $0.isSelected()) == true
        }
    }

    @discardableResult
    private func waitUntilSelected(isCompose: Bool, timeout: TimeInterval) -> Accessibility.Element? {
        try? Self.retry(withTimeout: timeout) { () throws -> Accessibility.Element in
            guard let selected = selectedCell() else { throw ErrorMessage("") }
            let desc = try? selected.localizedDescription()
            let isActuallyCompose = desc == nil
            guard isCompose == isActuallyCompose else { throw ErrorMessage("") }
            return selected
        }
    }

    static let composeURL = URL(string: "imessage://open?address=")!

    // performs `perform` while the Messages window is unhidden. Returns the new window title
    @discardableResult
    private func withActivation(
        openBefore: URL?, openAfter: URL?,
        perform: () throws -> Void
    ) throws -> String? {
        if let openBefore = openBefore {
            try NSWorkspace.shared.open(openBefore, options: [.andHide, .withoutActivation], configuration: [:])
        }

        try perform()

        let newTitle: String?
        if let openAfter = openAfter {
            debugLog("Returning to observed thread")
            let oldTitle = try mainWindow.windowTitle()
            try NSWorkspace.shared.open(openAfter, options: [.andHide, .withoutActivation], configuration: [:])
            newTitle = try? Self.retry(withTimeout: 1, interval: 0.1) {
                let newTitle = try mainWindow.windowTitle()
                // the message doesn't matter since we're try?-ing
                guard newTitle != oldTitle else { throw ErrorMessage("") }
                return newTitle
            }
        } else {
            newTitle = nil
        }

        return newTitle
    }

    private func deepLink(forMessage guid: String) throws -> URL {
        guard let firstPart = guid.split(separator: "_", maxSplits: 1).first,
              let guidParsed = UUID(uuidString: String(firstPart)), // extra validation ahead of time
              let url = URL(string: "imessage://open?message-guid=\(guidParsed)") else {
            throw ErrorMessage("Invalid iMessage guid \(guid)")
        }
        return url
    }

    private func deepLink(forAddresses addresses: [String], body: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"
        components.queryItems = [
            URLQueryItem(
                name: addresses.count == 1 ? "address" : "addresses",
                value: addresses.joined(separator: ",")
            ),
            URLQueryItem(name: "body", value: body)
        ]
        return try components.url
            .orThrow(ErrorMessage("Invalid iMessage addresses: \(addresses)"))
    }

    func createThread(addresses: [String]) throws {
        try NSWorkspace.shared.open(deepLink(forAddresses: addresses))
    }

    private func reactionsView() throws -> Accessibility.Element {
        guard let mainView = try mainWindow.children().first(where: { (try? $0.role()) == "AXGroup" }),
              (try? mainView.children.count()) ?? 0 >= 2,
              let presView = try? mainView.children.value(at: 0),
              (try? presView.children.count()) ?? 0 > 0 else {
            throw ErrorMessage("Could not find reactions view")
        }
        return presView
    }

    func setReaction(guid: String, offset: Int, reaction: Reaction, on: Bool) throws {
        debugLog("Finding cell at offset \(offset) from \(guid)")

        let url = try self.deepLink(forMessage: guid)

        activityLock.lock()
        defer { activityLock.unlock() }

        let idx = reaction.index
        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            guard let transcripts = mainWindow.child(withID: "TranscriptCollectionView") else {
                throw ErrorMessage("Could not find TranscriptCollectionView")
            }
            guard let selected = transcripts.recursiveChildren().first(where: { (try? $0.isSelected()) == true }) else {
                throw ErrorMessage("Could not find selected child")
            }
//            selected.printAttributes()
            let targetCell: Accessibility.Element
            if offset == 0 {
                targetCell = selected
            } else {
                let containerCell = try selected.parent()
                let containerFrame = try containerCell.frame()
                let siblings = try containerCell.parent().children().filter {
                    (try? $0.localizedDescription())?.isEmpty == false
                }
                guard let idx = siblings.firstIndex(where: { (try? $0.frame()) == containerFrame }) else {
                    throw ErrorMessage("Could not find target cell")
                }
                let target = idx - offset
                debugLog("Index: \(idx) - \(offset) = \(target)")
                guard siblings.indices.contains(target) else {
                    throw ErrorMessage("Desired index out of bounds")
                }
                targetCell = try siblings[target].children.value(at: 0)
            }
//            targetCell.printAttributes()
            let allActions = try targetCell.supportedActions()
            // TODO: Does "React" need to be localized here?
            guard let reactAction = allActions.first(where: { $0.name.value.contains("Name:React") }) else {
                throw ErrorMessage("Could not find react action")
            }
            try reactAction()
            let reactionsView = try Self.retry(withTimeout: 2, interval: 0.1) { try self.reactionsView() }
            guard let buttons = try? reactionsView.children().filter({ (try? $0.role()) == "AXButton" }),
                  buttons.count == 7 // last button is Reply
            else { throw ErrorMessage("Could not find reaction buttons") }
            let btn = buttons[idx]
            let isSelected = try btn.isSelected()
            if isSelected != on {
                try btn.press()
            }
        }
    }

    func markAsRead(guid: String) throws {
        let url = try self.deepLink(forMessage: guid)

        activityLock.lock()
        defer { activityLock.unlock() }

        try withActivation(openBefore: Self.composeURL, openAfter: activityObserver?.url) {
            guard let composeCell = waitUntilSelected(isCompose: true, timeout: 0.5) else {
                throw ErrorMessage("Could not find selected new message cell")
            }

            debugLog("Opened compose. Opening target URL")
            try NSWorkspace.shared.open(url, options: [.andHide, .withoutActivation], configuration: [:])

            guard let targetCell = waitUntilSelected(isCompose: false, timeout: 0.5) else {
                debugLog("warning: Cell for message \(guid) could not be found.")
                return
            }

            // we now click another cell and then come back

            debugLog("Pressing compose cell")

            try composeCell.press()

            waitUntilSelected(isCompose: true, timeout: 0.5)

            debugLog("Pressing target cell")

            try targetCell.press()

            waitUntilSelected(isCompose: false, timeout: 0.5)

            debugLog("Done!")
        }
    }

    func sendTypingStatus(_ isTyping: Bool, address: String) throws {
        debugLog("Sending typing status \(isTyping) for address \(address)")

        // a space is enough to send a typing indicator, while ensuring that
        // users can't accidentally hit return to send a single-char message
        // (since Messages special-cases space-only messages). The NUL byte
        // is another option that doesn't get sent to the server, but it
        // shows up client-side as a ghost message.
        let url = try self.deepLink(forAddresses: [address], body: isTyping ? " " : nil)

        activityLock.lock()
        defer { activityLock.unlock() }

        let initialTitle = try? mainWindow.windowTitle()

        try withActivation(openBefore: url, openAfter: activityObserver?.url) {
            if isTyping { return } // no further action required

            try? Self.retry(withTimeout: 0.5, interval: 0.1) {
                guard try mainWindow.windowTitle() != initialTitle else {
                    throw ErrorMessage("")
                }
            }

            let messageField = try Self.retry(withTimeout: 1, interval: 0.1) {
                try mainWindow.child(withID: "messageBodyField")
                    .orThrow(ErrorMessage("Could not find message body field"))
            }
            try messageField.value(assign: "")
        }
    }

    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        do {
            try mainWindow.window().moveToSpace(lastActiveDisplay.currentSpace())
        } catch {
            debugLog("warning: Could not show Messages window: \(error)")
        }
    }

    private func deactivateMessages() {
        do {
            lastActiveDisplay = try Self.moveWindow(mainWindow, to: space)
        } catch {
            debugLog("warning: Could not hide Messages window: \(error)")
        }
    }

    private func activityStatus() -> ActivityStatus {
        guard let transcripts = mainWindow.child(withID: "TranscriptCollectionView"),
              let count = try? transcripts.children.count(),
              count > 0,
              let elt = try? transcripts.children.value(at: count - 1) else {
            return .unknown
        }
        // children can briefly be 0 for newly sent messages as well, so
        // that by itself isn't a good enough heuristic
        let isTyping = (try? elt.children.count()) == 0 && (try? elt.roleDescription().isEmpty) != false
        return isTyping ? .typing : .notTyping
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

        guard (try? mainWindow.windowTitle()) == observer.windowTitle else {
//            debugLog("warning: Title changed. Not polling activity status.")
            observer.send(.unknown)
            return
        }

        observer.send(activityStatus())
    }

    // must call with lock held
    private func _removeObserver() throws {
        if let old = activityObserver {
            old.send(.notTyping)
            activityObserver = nil
        }
    }

    func removeObserver() throws {
        activityLock.lock()
        defer { activityLock.unlock() }
        try _removeObserver()
    }

    func observe(address: String, callback: @escaping (ActivityStatus) -> Void) throws {
        let url = try deepLink(forAddresses: [address])

        activityLock.lock()
        defer { activityLock.unlock() }

        // we remove the previous observer first, so that if
        // this method fails we don't keep sending notifs to the old
        // observer. We only update to the new observer once we've
        // successfully switched chats.
        try _removeObserver()

        let title = try withActivation(openBefore: nil, openAfter: url) {} ?? mainWindow.windowTitle()
        debugLog("Observing with title \(title)")

        activityObserver = .init(address: address, url: url, windowTitle: title, callback: callback)
    }

    // this is called before the final deinit
    func dispose() {
        app.terminate()
    }

    deinit {
        timer?.invalidate()
        loopThread?.cancel()
    }
}
