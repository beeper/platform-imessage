import AccessibilityControl
import AppKit
import IMessageCore
import Logging

private let messagesApplicationLog = Logger(imessageLabel: "messages-application")

final class MessagesApplication {
    typealias OpenDeepLink = (URL) async throws -> Void

    let runningApplication: NSRunningApplication
    let accessibilityElement: Accessibility.Element

    private let openDeepLink: OpenDeepLink
    private var lastDumpedApplicationTree: Date?

    var processIdentifier: pid_t {
        runningApplication.processIdentifier
    }

    init(runningApplication: NSRunningApplication, openDeepLink: @escaping OpenDeepLink) {
        self.runningApplication = runningApplication
        self.openDeepLink = openDeepLink
        accessibilityElement = Accessibility.Element(pid: runningApplication.processIdentifier)
    }

    func allWindows() -> [Window] {
        var elements = (try? accessibilityElement.appWindows()) ?? []

        // after a window is moved to a new Space, AX may not list it consistently in appWindows or children, so keep the focused/main fallbacks.
        if let mainWindow: Accessibility.Element = try? accessibilityElement.appMainWindow(), !elements.contains(mainWindow) {
            elements.append(mainWindow)
        }

        if let focusedWindow: Accessibility.Element = try? accessibilityElement.appFocusedWindow(), !elements.contains(focusedWindow) {
            elements.append(focusedWindow)
        }

        return elements.map(window(for:))
    }

    func currentWindow() -> Window? {
        mainWindow()
    }

    func mainWindow() -> Window? {
        allWindows()
            .first(where: isMainWindow)
    }

    func isMainWindow(_ window: Window) -> Bool {
        isMainWindow(window.element)
    }

    fileprivate func window(for element: Accessibility.Element) -> Window {
        Window(parent: self, element: element)
    }

    func isMainWindow(_ element: Accessibility.Element) -> Bool {
        // These checks are intentionally redundant. Depending on macOS version
        // and Spaces state, one path can fail while the other still identifies
        // the Messages main window.
        conversationList(in: element, useFastPath: false) != nil ||
            ckConversationListCollectionView(in: element) != nil
    }

    func sectionObjects(in element: Accessibility.Element) throws -> [Accessibility.Element] {
        try element.sections().compactMap {
            $0["SectionObject"].flatMap { Accessibility.Element(erased: $0) }
        }
    }

    func conversationList(in element: Accessibility.Element, useFastPath: Bool) -> Accessibility.Element? {
        if useFastPath,
           let conversationList = try? sectionObjects(in: element)
                .first(where: { (try? $0.identifier()) == "ConversationList" }) {
            return conversationList
        }

        return element.recursivelyFindChild(withID: "ConversationList")
    }

    func ckConversationListCollectionView(in element: Accessibility.Element) -> Accessibility.Element? {
        element.recursivelyFindChild(withID: "CKConversationListCollectionView")
    }

    fileprivate func recoverMissingWindow(after attempt: Int, error _: Error?) async throws {
        if attempt == 0 {
            messagesApplicationLog.notice("availableWindow: using compose deep link to try to get main window")
            try await openDeepLink(MessagesDeepLink.compose.url())
        } else if attempt == 1 {
            if isPromptVisible() {
                messagesApplicationLog.notice("availableWindow: some prompts are visible, attempting to reset")
                Defaults.resetPrompts()
            }
        } else if attempt == 2 {
            if isPromptVisible() {
                messagesApplicationLog.error("availableWindow: some prompts are still visible, force terminating")
                runningApplication.forceTerminate()
            }
        } else if attempt > 3 {
            do {
                try dismissAnyPresentedSheet()
            } catch {
                messagesApplicationLog.error("availableWindow: couldn't try dismissing any presented sheet: \(error)")
            }
        }
    }

    fileprivate func dumpAndLogApplicationTreeIfNeeded() throws {
        if let lastDumpedApplicationTree {
            guard lastDumpedApplicationTree.elapsedMilliseconds >= 60_000 else {
                messagesApplicationLog.debug("not dumping application tree as it was dumped less than a minute ago")
                return
            }
        }

        defer { lastDumpedApplicationTree = Date() }
        var buffer = ""
        try accessibilityElement.dumpXML(to: &buffer, maxDepth: 10, excludingPII: true, includeActions: false, includeSections: true)
        messagesApplicationLog.info("\(buffer)")
    }

    private func isPromptVisible() -> Bool {
        allWindows().contains(where: { (try? $0.element.windowCloseButton().isEnabled()) == false })
    }

    private func dismissAnyPresentedSheet() throws {
        let mainWindow = try accessibilityElement.appMainWindow()
        guard let sheet = mainWindow.firstChild(withRole: \.sheet) else {
            messagesApplicationLog.debug("(found no sheet to dismiss)")
            return
        }

        let startTime = Date()
        guard let okButton = sheet.recursiveChildren().lazy.first(where: { child in
            let description = try? child.localizedDescription()
            return description == LocalizedStrings.dismissButtonLabel || description == LocalizedStrings.ok
        }) else {
            messagesApplicationLog.debug("found a sheet, but no OK button within it to dismiss (took \(startTime.elapsedMilliseconds)ms)")
            return
        }

        messagesApplicationLog.debug("found OK button within sheet, going to press it (took \(startTime.elapsedMilliseconds)ms)")
        do {
            try okButton.press()
        } catch {
            messagesApplicationLog.error("couldn't press OK button: \(error)")
        }
    }
}

extension MessagesApplication {
    enum WindowAvailability {
        static func availableWindow(for application: MessagesApplication) async throws -> Window {
            do {
                return try await retry(withTimeout: 5, interval: 0.2) { () async throws -> Window in
                    try application.mainWindow().orThrow(ErrorMessage("Could not get main Messages window"))
                } onError: { attempt, error in
                    try await application.recoverMissingWindow(after: attempt, error: error)
                }
            } catch {
                do {
                    try application.dumpAndLogApplicationTreeIfNeeded()
                } catch {
                    messagesApplicationLog.error("couldn't dump application tree: \(String(describing: error))")
                }
                throw error
            }
        }
    }
}
