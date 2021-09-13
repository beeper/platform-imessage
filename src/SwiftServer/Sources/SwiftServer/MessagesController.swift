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

extension Accessibility.Attribute.Name {
    static let children = Accessibility.Attribute.Name(kAXChildrenAttribute)
    static let localizedDescription = Accessibility.Attribute.Name(kAXDescriptionAttribute)
}

extension Accessibility.Action.Name {
    static let press = Accessibility.Action.Name(kAXPressAction)
}

extension Accessibility.Element {
    var isValid: Bool {
        (try? pid()) != nil
    }

    func appMainWindow() throws -> Accessibility.Element? {
        let mainWindowRaw = try attribute(.init(kAXMainWindowAttribute))
        return Accessibility.Element(erased: mainWindowRaw)
    }

    func children() -> [Accessibility.Element] {
        let rawChildren = try? attribute(.children) as? [AXUIElement]
        return rawChildren?.map(Accessibility.Element.init(raw:)) ?? []
    }

    // breadth-first, seems faster than dfs
    func recursiveChildren() -> AnySequence<Accessibility.Element> {
        AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            let elt = queue.removeFirst()
            queue.append(contentsOf: elt.children())
            return elt
        })
    }

    func child(withID id: String) throws -> Accessibility.Element? {
        recursiveChildren().lazy.first {
            (try? $0.attribute("AXIdentifier") as? String) == id
        }
    }

    func printAttributes() {
        for act in (try? supportedActions()) ?? [] {
            print("[action] \(act.name): \(act.description)")
        }
        for att in (try? supportedAttributes()) ?? [] {
            print("[regular] \(att.name): \((try? att.get()) as Any)")
        }
        for att in (try? supportedParameterizedAttributes()) ?? [] {
            print("[parameterized] \(att)")
        }
    }

    func setWindowPosition(_ pos: CGPoint) throws {
        try setAttribute("AXPosition", to: Accessibility.Struct.point(pos).raw()!)
    }

    func setWindowSize(_ size: CGSize) throws {
        try setAttribute("AXSize", to: Accessibility.Struct.size(size).raw()!)
    }

    func setWindowFrame(_ frame: CGRect) throws {
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            switch i {
            case 0:
                try? setWindowPosition(frame.origin)
            case 1:
                try? setWindowSize(frame.size)
            default:
                break
            }
        }
    }

    func windowFrame() throws -> CGRect {
        guard let val = try Accessibility.Struct(erased: attribute("AXFrame")) else {
            throw ErrorMessage("Could not get frame for window \(self)")
        }
        guard case let .rect(rect) = val else {
            throw ErrorMessage("Window frame for \(self) isn't a CGRect?")
        }
        return rect
    }
}

// not thread safe
class MessagesController {
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

        guard let textsApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.textsBundleID).first else {
            throw ErrorMessage("Could not find running Texts instance")
        }
        let textsAppElement = Accessibility.Element(pid: textsApp.processIdentifier)
        self.textsWindow = try Self.retry(withTimeout: 10, interval: 0.1) { () throws -> Accessibility.Element in
            guard let textsWindow = try textsAppElement.appMainWindow() else {
                throw ErrorMessage("Could not find Texts main window")
            }
            return textsWindow
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleID).first {
            app = running
        } else {
            print("Launching Messages...")
            app = try NSWorkspace.shared.launchApplication(at: Self.messagesBundle, options: .andHide, configuration: [:])
        }
        appElement = Accessibility.Element(pid: app.processIdentifier)

        self.mainWindow = try Self.retry(withTimeout: 10, interval: 0.1) { [appElement] () throws -> Accessibility.Element in
            guard let child = appElement.children().first(
                where: { (try? $0.attribute("AXIdentifier") as? String) == "SceneWindow" }
            ) else {
                throw ErrorMessage("Could not get main Messages window")
            }
            return child
        }

        guard let toolbar = mainWindow.children().first(where: {
            (try? $0.attribute("AXRole") as? String) == "AXToolbar"
        }) else { throw ErrorMessage("Could not get main toolbar") }
        self.toolbar = toolbar

        guard let conversations = try? mainWindow.child(withID: "ConversationList") else {
            throw ErrorMessage("Could not get Messages conversation list")
        }
        self.conversations = conversations

        #if false
        // FIXME: don't move if already visible
        try setWindowFrame(CGRect(x: 500, y: 25, width: 700, height: 300))
        #endif
    }

    var isValid: Bool {
        !app.isTerminated &&
            [toolbar, conversations, textsWindow].allSatisfy(\.isValid)
    }

    // the button seems to get invalidated every so often
    // so we can't cache it
    private func findComposeButton() throws -> Accessibility.Element? {
        // TODO: is it first in RTL envs?
        toolbar.children().first
    }

    private func selectedCell() -> Accessibility.Element? {
        conversations.children().first {
            (try? $0.attribute(.init(kAXSelectedAttribute)) as? Bool) == true
        }
    }

    @discardableResult
    private func waitUntilSelected(isCompose: Bool, timeout: TimeInterval) -> Accessibility.Element? {
        let start = Date()
        while -start.timeIntervalSinceNow < timeout {
            guard let selected = selectedCell() else { continue }
            let desc = try? selected.attribute(.localizedDescription)
            let isActuallyCompose = desc == nil
            if isCompose == isActuallyCompose {
                return selected
            }
        }
        return nil
    }

    func markAsRead(guid: String) throws {
        guard let firstPart = guid.split(separator: "_", maxSplits: 1).first,
              let guidParsed = UUID(uuidString: String(firstPart)), // extra validation ahead of time
              let url = URL(string: "imessage://open?message-guid=\(guidParsed)") else {
            throw ErrorMessage("Invalid iMessage guid \(guid)")
        }

        if (try? mainWindow.attribute("AXMinimized") as? Bool) == true {
            try mainWindow.setAttribute("AXMinimized", to: false as AnyObject)
            app.hide()
            while (try? mainWindow.attribute("AXMinimized") as? Bool) == true {}
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

        guard let composeButton = try? findComposeButton() else {
            print("warning: Could not find compose button")
            return
        }
        print("Pressing compose")
        try composeButton.perform(action: .press)
        guard let newCell = waitUntilSelected(isCompose: true, timeout: 1) else {
            print("warning: New message cell could not be found")
            return
        }

        print("Compose pressed. Opening URL")

        try NSWorkspace.shared.open(url, options: [.andHide, .withoutActivation], configuration: [:])

        guard let targetCell = waitUntilSelected(isCompose: false, timeout: 0.5) else {
            print("warning: Cell for message \(guid) could not be found.")
            return
        }

        // we now click another cell and then come back

        print("Pressing new cell")

        try newCell.perform(action: .press)

        waitUntilSelected(isCompose: true, timeout: 0.5)

        print("Pressing target cell")

        try targetCell.perform(action: .press)

        print("Done!")
    }
}
