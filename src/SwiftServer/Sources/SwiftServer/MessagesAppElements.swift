import AppKit
import AccessibilityControl

/// MessagesAppElements contains all the fetching code (with retry) for `Accessibility.Element`s that MessagesController uses
/// aim to reduce side effects (like calling actions) here
final class MessagesAppElements {
    static func isThreadCellCompose(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription()) == nil
    }

    static func isMessageContainerCell(_ el: Accessibility.Element) -> Bool {
        (try? el.localizedDescription())?.isEmpty == false &&
            (try? el.children.value(at: 0).supportedActions().contains(where: { $0.name.value.hasPrefix("Name:\(LocalizedStrings.react)") })) == true
    }

    static func messageContainerCells(in tv: Accessibility.Element) throws -> [Accessibility.Element] {
        try tv.children().filter(Self.isMessageContainerCell)
    }

    static func firstMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        try tv.children().first(where: Self.isMessageContainerCell)?.children.value(at: 0)
    }

    static func firstSelectedMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        // selectedChildren wont work here
        // tv.children().first { (try? $0.selectedChildren.value(at: 0)) != nil }?.children.value(at: 0)
        try tv.children().first { (try? $0.children.value(at: 0).isSelected()) == true }?.children.value(at: 0)
    }

    private let whm: WindowHidingManager
    private let runningApp: NSRunningApplication

    let app: Accessibility.Element

    // private var cachedConversationsList: Accessibility.Element?
    // private var cachedTranscriptView: Accessibility.Element?
    // private var cachedReplyTranscriptView: Accessibility.Element?
    private var cachedMainWindow: Accessibility.Element?

    // private func clearCachedElements() {
    //     // these are manually cleared because we aren't checking for validity on each property access
    //     // for cachedConversationsList, isValid/isFrameValid/isInViewport all return true even after the main window is closed
    //     cachedConversationsList = nil
    //     cachedTranscriptView = nil
    //     cachedReplyTranscriptView = nil
    // }

    init(runningApp: NSRunningApplication, whm: WindowHidingManager) {
        self.runningApp = runningApp
        self.whm = whm
        app = Accessibility.Element(pid: runningApp.processIdentifier)
    }

    var allWindows: [Accessibility.Element] { // takes ~0ms
        get {
            // after a window is moved to the new space, AX doesn't list the window in appWindows or children
            (((try? app.appWindows()) ?? []) + [try? app.appMainWindow(), try? app.appFocusedWindow()]).compactMap { $0 }
        }
    }

    func getMainWindow() -> Accessibility.Element? { // takes ~24ms
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

    private func isPromptVisibleInMessagesApp() -> Bool {
        allWindows.contains(where: { (try? $0.windowCloseButton().isEnabled()) == false })
    }

    var mainWindow: Accessibility.Element {
        get throws {
            if let cached = cachedMainWindow, cached.isFrameValid {
                return cached
            }
            let mainWindow = try retry(withTimeout: 5, interval: 0.2) { () throws -> Accessibility.Element in
                try getMainWindow().orThrow(ErrorMessage("Could not get main Messages window"))
            } onError: { attempt, _ in
                if attempt == 0 {
                    debugLog("Opening compose deep link to get main window")
                    try MessagesController.openDeepLink(MessagesDeepLink.compose.url())
                } else if attempt == 1 {
                    if self.isPromptVisibleInMessagesApp() {
                        Logger.log("Prompts visible, resetting prompts")
                        Defaults.resetPrompts()
                    }
                } else if attempt == 2 {
                    if self.isPromptVisibleInMessagesApp() {
                        Logger.log("Prompts visible still, force terminating")
                        // regular terminate wont work since all window close buttons are disabled
                        self.runningApp.forceTerminate()
                        // this should invalidate the MessagesController
                    }
                }
            }
            try? MessagesController.resizeWindowToMaxHeight(mainWindow)
            try? whm.mainWindowChanged(mainWindow)
            // clearCachedElements()
            cachedMainWindow = mainWindow
            return mainWindow
        }
    }

    var conversationsList: Accessibility.Element { // takes ~34ms
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
                    .orThrow(ErrorMessage("ConversationList not found"))
            } onError: { _, _ in
                let searchField = try self.searchField
                debugLog("fetching ConversationList errored, calling searchField.cancel")
                // this will close the search results if active
                try searchField.cancel()
            }
            // cachedConversationsList = cl
            return cl
        }
    }

    // this return type was copied from compiler error
    var mainWindowSections: LazyMapCollection<LazyFilterSequence<LazyMapSequence<LazySequence<[[String: CFTypeRef]]>.Elements, Accessibility.Element?>>, Accessibility.Element> {
        get throws {
            try mainWindow.sections().lazy.compactMap { $0["SectionObject"].flatMap { Accessibility.Element(erased: $0) } }
        }
    }

    var composeCell: Accessibility.Element? {
        get {
            try? conversationsList.children().first(where: Self.isThreadCellCompose)
        }
    }

    var selectedThreadCell: Accessibility.Element? {
        get {
            try? conversationsList.selectedChildren.value(at: 0)
        }
    }

    private func getTranscriptView(replyTranscript: Bool) throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { Logger.log("getTranscriptView(replyTranscript: \(replyTranscript)) took \(startTime.timeIntervalSinceNow * -1000)ms") }
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
            .orThrow(ErrorMessage("TranscriptCollectionView(replyTranscript: \(replyTranscript)) not found"))
    }

    var transcriptView: Accessibility.Element {
        get throws {
            // if let cached = cachedTranscriptView, cached.isInViewport {
            //     return cached
            // }
            let tcv = try getTranscriptView(replyTranscript: false)
            // cachedTranscriptView = tcv
            return tcv
        }
    }

    var replyTranscriptView: Accessibility.Element {
        get throws {
            // if let cached = cachedReplyTranscriptView, cached.isInViewport {
            //     return cached
            // }
            let tcv = try getTranscriptView(replyTranscript: true)
            // cachedReplyTranscriptView = tcv
            return tcv
        }
    }

    var messagesField: Accessibility.Element {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("messagesField took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try retry(withTimeout: 1.5, interval: 0.1) {
                try mainWindow.recursivelyFindChild(withID: "messageBodyField")
                    .orThrow(ErrorMessage("messageBodyField not found"))
            }
        }
    }

    var searchField: Accessibility.Element {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("searchField took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try retry(withTimeout: 1.5, interval: 0.1) {
                let CKConversationListCollectionView = try mainWindow.recursivelyFindChild(withID: "CKConversationListCollectionView")
                    .orThrow(ErrorMessage("CKConversationListCollectionView not found"))
                return try CKConversationListCollectionView.children().first { (try? $0.subrole()) == AXRole.searchField }
                    .orThrow(ErrorMessage("searchField not found"))
            }
        }
    }

    var iOSContentGroup: Accessibility.Element { // className=UINSSceneView
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("iOSContentGroup took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try mainWindow.children().first(where: { (try? $0.subrole()) == "iOSContentGroup" && (try? $0.role()) == AXRole.group })
                .orThrow(ErrorMessage("iOSContentGroup not found"))
        }
    }

    var iOSContentGroupFirstChild: Accessibility.Element { // className= CKUIWindow_60754894 or CKPresentationControllerWindow (when reactions are open)
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("iOSContentGroupFirstChild took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try (try? iOSContentGroup.children.value(at: 0))
                .orThrow(ErrorMessage("iOSContentGroupFirstChild not found"))
        }
    }

    var splitter: Accessibility.Element {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("splitter took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try iOSContentGroupFirstChild.children().first(where: { (try? $0.role()) == AXRole.splitter })
                .orThrow(ErrorMessage("splitter not found"))
        }
    }

    var reactionsView: Accessibility.Element {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("reactionsView took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            return try retry(withTimeout: 1.5, interval: 0.1) {
                let view = try iOSContentGroupFirstChild
                guard (try? view.children.count()) ?? 0 > 0 else {
                    throw ErrorMessage("reactionsView not found")
                }
                return view
            }
        }
    }

    var reactButtons: [Accessibility.Element] {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("reactButtons took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
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
            guard let buttons = try? reactionsView.children().filter({ (try? $0.role()) == AXRole.button }) else {
                throw ErrorMessage("reactButtons not found")
            }
            return buttons
        }
    }

    var alertSheet: Accessibility.Element {
        get throws {
            try mainWindow.children().first(where: { try $0.role() == AXRole.sheet }).orThrow(ErrorMessage("alertSheet not found"))
        }
    }

    var alertSheetDeleteButton: Accessibility.Element {
        get throws {
            try alertSheet.children().first(where: { try $0.role() == AXRole.button }).orThrow(ErrorMessage("deleteButton not found"))
        }
    }

    var notifyAnywayButton: Accessibility.Element {
        get throws {
            #if DEBUG
            let startTime = Date()
            defer { Logger.log("notifyAnywayButton took \(startTime.timeIntervalSinceNow * -1000)ms") }
            #endif
            let tv = try transcriptView
            let count = try tv.children.count()
            return try transcriptView.children(range: (count - 2)..<count).first(where: {
                let child = try $0.children.value(at: 0)
                return (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway && (try? child.role()) == AXRole.button
            }).orThrow(ErrorMessage("notifyAnywayButton not found"))
        }
    }
}
