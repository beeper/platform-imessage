import Foundation
import AppKit
import AccessibilityControl

struct ErrorMessage: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String { message }
}

// will be optimized out in release mode
@_transparent
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

extension Accessibility.Notification {
    static let layoutChanged = Self(kAXLayoutChangedNotification)
}

extension Accessibility.Names {
    var children: AttributeName<[Accessibility.Element]> { .init(kAXChildrenAttribute) }
    var appMainWindow: AttributeName<Accessibility.Element> { .init(kAXMainWindowAttribute) }

    var windowPosition: MutableAttributeName<CGPoint> { .init(kAXPositionAttribute) }
    var windowSize: MutableAttributeName<CGSize> { .init(kAXSizeAttribute) }
    var windowFrame: AttributeName<CGRect> { "AXFrame" }

    var localizedDescription: AttributeName<String> { .init(kAXDescriptionAttribute) }
    var identifier: AttributeName<String> { .init(kAXIdentifierAttribute) }
    var role: AttributeName<String> { .init(kAXRoleAttribute) }

    var isSelected: AttributeName<Bool> { .init(kAXSelectedAttribute) }
    var isMinimized: MutableAttributeName<Bool> { .init(kAXMinimizedAttribute) }

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
            print("[action] \(act.name): \(act.description)")
        }
        for att in (try? supportedAttributes()) ?? [] {
            print("[regular] \(att.name): \((try? att()) as Any)")
        }
        for att in (try? supportedParameterizedAttributes()) ?? [] {
            print("[parameterized] \(att)")
        }
    }

    func setWindowFrame(_ frame: CGRect) throws {
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            switch i {
            case 0:
                try? self.windowPosition(assign: frame.origin)
            case 1:
                try? self.windowSize(assign: frame.size)
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

// external API is not thread safe
final class MessagesController {
    struct ActivityObserver {
        let address: String
        // may be called on a bg thread
        let callback: (String) -> Void
        let url: URL

        init(address: String, callback: @escaping (String) -> Void) throws {
            guard let url = URL(string: "imessage://open?address=\(address)") else {
                throw ErrorMessage("Invalid iMessage address: \(address)")
            }
            self.address = address
            self.callback = callback
            self.url = url
        }
    }

    static let queue = DispatchQueue(label: "swift-server-queue")

    private static let textsBundleID = "com.kishanbagaria.jack"
    private static let messagesBundleID = "com.apple.MobileSMS"
    private static let messagesBundle = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: messagesBundleID
    )!

    private static let shadowMargin: CGFloat = 32
    // iMessage doesn't go smaller than this
    private static let minSize = CGSize(width: 660, height: 320)
    // the Texts sidebar (usually) takes up at most this proportion
    // of the window's width
    private static let sidebarWidthFactor: CGFloat = 0.5

    private let textsWindow: Accessibility.Element
    private let app: NSRunningApplication
    private let appElement: Accessibility.Element
    private let mainWindow: Accessibility.Element
    private let toolbar: Accessibility.Element
    private let conversations: Accessibility.Element

    private var timer: Timer?
    private var loopThread: RunLoopThread?
    private var token: Accessibility.Observer.Token?

    private var activityObserver: ActivityObserver?

    private static func messagesFrame(for textsFrame: CGRect) -> CGRect {
        let targetWidth = max(Self.minSize.width, textsFrame.width * Self.sidebarWidthFactor - Self.shadowMargin)
        let targetHeight = max(Self.minSize.height, textsFrame.height - Self.shadowMargin)
        return CGRect(
            x: textsFrame.maxX - targetWidth,
            y: textsFrame.maxY - targetHeight,
            width: targetWidth,
            height: targetHeight
        )
    }

    private static func retry<T>(
        withTimeout timeout: TimeInterval,
        interval: TimeInterval,
        _ perform: () throws -> T
    ) throws -> T {
        let start = Date()
        var res: Result<T, Error>
        repeat {
            res = Result(catching: perform)
            if case let .success(val) = res {
                return val
            }
            Thread.sleep(forTimeInterval: interval)
        } while -start.timeIntervalSinceNow < timeout
        return try res.get()
    }

    init() throws {
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Texts does not have Accessibility permissions")
        }

        // TODO: Can we parallelize fetching the Texts and Messages windows?

        guard let textsApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.textsBundleID).first else {
            throw ErrorMessage("Could not find running Texts instance")
        }
        let textsAppElement = Accessibility.Element(pid: textsApp.processIdentifier)
        self.textsWindow = try Self.retry(withTimeout: 10, interval: 0.1) { () throws -> Accessibility.Element in
            guard let textsWindow = try? textsAppElement.appMainWindow() else {
                throw ErrorMessage("Could not find Texts main window")
            }
            return textsWindow
        }

        let alreadyRunning: Bool
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID).first {
            app = running
            alreadyRunning = true
        } else {
            debugLog("Launching Messages...")
            app = try NSWorkspace.shared.launchApplication(at: Self.messagesBundle, options: .andHide, configuration: [:])
            alreadyRunning = false
        }
        appElement = Accessibility.Element(pid: app.processIdentifier)

        let getMainWindow = { [appElement] () throws -> Accessibility.Element in
            guard let child = try? appElement.children().first(
                where: { (try? $0.identifier()) == "SceneWindow" }
            ) else {
                throw ErrorMessage("Could not get main Messages window")
            }
            return child
        }

        if alreadyRunning {
            // the main Messages window might be closed. Let's open it
            let url = URL(string: "imessage://")!
            try NSWorkspace.shared.open(url, options: [.andHide, .withoutActivation], configuration: [:])
        }

        self.mainWindow = try Self.retry(withTimeout: alreadyRunning ? 2 : 10, interval: 0.1, getMainWindow)

        if alreadyRunning {
            // we can hide Messages
            app.hide()
        }

        guard let toolbar = try? mainWindow.children().first(where: {
            (try? $0.role()) == "AXToolbar"
        }) else { throw ErrorMessage("Could not get main toolbar") }
        self.toolbar = toolbar

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
                timeInterval: 0.5,
                target: watcher,
                selector: #selector(TimerBlockWatcher.timerFired),
                userInfo: nil,
                repeats: true
            )
        }
        thread.qualityOfService = .utility
        thread.start()
        self.loopThread = thread

        #if false
        // FIXME: don't move if already visible
        try setWindowFrame(CGRect(x: 500, y: 25, width: 700, height: 300))
        #endif
    }

    var isValid: Bool {
        !app.isTerminated
            && (try? mainWindow.windowFrame()) != nil
            && (try? textsWindow.windowFrame()) != nil
            && toolbar.isValid
            && conversations.isValid
    }

    // the button seems to get invalidated every so often
    // so we can't cache it
    private func findComposeButton() throws -> Accessibility.Element? {
        // TODO: is it first in RTL envs?
        try? toolbar.children().first
    }

    private func selectedCell() -> Accessibility.Element? {
        try? conversations.children().first {
            (try? $0.isSelected()) == true
        }
    }

    @discardableResult
    private func waitUntilSelected(isCompose: Bool, timeout: TimeInterval) -> Accessibility.Element? {
        let start = Date()
        while -start.timeIntervalSinceNow < timeout {
            guard let selected = selectedCell() else { continue }
            let desc = try? selected.localizedDescription()
            let isActuallyCompose = desc == nil
            if isCompose == isActuallyCompose {
                return selected
            }
        }
        return nil
    }

    private func compose(attempt: Int = 0) throws -> Accessibility.Element {
        guard let composeButton = try? findComposeButton() else {
            if attempt < 5 {
                return try compose(attempt: attempt + 1)
            } else {
                throw ErrorMessage("Could not find compose button")
            }
        }
        try composeButton.press()
        guard let newCell = waitUntilSelected(isCompose: true, timeout: 0.5) else {
            if attempt < 5 {
                return try compose(attempt: attempt + 1)
            } else {
                throw ErrorMessage("Could not find selected new message cell")
            }
        }
        return newCell
    }

    func markAsRead(guid: String) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        guard let firstPart = guid.split(separator: "_", maxSplits: 1).first,
              let guidParsed = UUID(uuidString: String(firstPart)), // extra validation ahead of time
              let url = URL(string: "imessage://open?message-guid=\(guidParsed)") else {
            throw ErrorMessage("Invalid iMessage guid \(guid)")
        }

        if (try? mainWindow.isMinimized()) == true {
            try mainWindow.isMinimized(assign: false)
            app.hide()
            while (try? mainWindow.isMinimized()) == true {}
        }

        let changeVisibility = true // app.isHidden
        if app.isHidden {
            app.unhide()
            while app.isHidden {
                // spin
            }
        }

        let textsFrame = try textsWindow.windowFrame()
        let targetFrame = Self.messagesFrame(for: textsFrame)
        let oldFrame = try mainWindow.windowFrame()
        let changeFrame = oldFrame != targetFrame
//            // iff oldFrame is contained inside textsFrame
//            && (changeVisibility || oldFrame.intersection(textsFrame) == oldFrame)
        if changeFrame {
            try mainWindow.setWindowFrame(targetFrame)
            while (try? mainWindow.windowFrame()) == oldFrame {}
        }

        defer {
            if changeVisibility {
                app.hide()
            }
//            if changeFrame {
//                try? mainWindow.setWindowFrame(oldFrame)
//            }
        }

        debugLog("Pressing compose")
        let newCell = try compose()

        debugLog("Compose pressed. Opening URL")
        try NSWorkspace.shared.open(url, options: [.andHide, .withoutActivation], configuration: [:])

        guard let targetCell = waitUntilSelected(isCompose: false, timeout: 0.5) else {
            print("warning: Cell for message \(guid) could not be found.")
            return
        }

        // we now click another cell and then come back

        debugLog("Pressing new cell")

        try newCell.press()

        waitUntilSelected(isCompose: true, timeout: 0.5)

        debugLog("Pressing target cell")

        try targetCell.press()

        if let observer = activityObserver {
            waitUntilSelected(isCompose: false, timeout: 0.5)

            debugLog("Returning to observer")

            try openObserverThread(observer)
        }

        debugLog("Done!")
    }

    private func isTyping() -> Bool {
        guard let transcripts = mainWindow.child(withID: "TranscriptCollectionView"),
              let count = try? transcripts.children.count(),
              count > 0,
              let elt = try? transcripts.children(range: (count - 1)..<count).first else {
            return false
        }
        return (try? elt.children.count()) == 0
    }

    // TODO: Switch to os_unfair_lock if we drop old OSes
    private let activityLock = NSLock()

    // called on run loop thread, not main node thread
    private func pollActivityStatus() {
        // if someone else (setObserver) holds the lock,
        // silently skip this polling attempt
        guard activityLock.try() else { return }
        defer { activityLock.unlock() }

        guard let observer = activityObserver else { return }

        if self.isTyping() {
            observer.callback(observer.address)
        }
    }

    // must be called with the observer lock held
    private func openObserverThread(_ observer: ActivityObserver) throws {
        try NSWorkspace.shared.open(observer.url, options: [.andHide, .withoutActivation], configuration: [:])
        Thread.sleep(forTimeInterval: 0.2)
        app.hide()
    }

    func setObserver(_ observer: ActivityObserver?) throws {
        activityLock.lock()
        defer { activityLock.unlock() }

        // we unconditionally nil out the observer first, so that if
        // this method fails we don't keep sending notifs to the old
        // observer. We only update to the new observer once we've
        // successfully switched chats.
        activityObserver = nil
        guard let observer = observer else { return }

        try openObserverThread(observer)

        activityObserver = observer
    }

    deinit {
        timer?.invalidate()
        loopThread?.cancel()
    }
}
