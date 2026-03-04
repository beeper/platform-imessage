import AppKit
import AccessibilityControl
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "app-elements")

struct ElementSearchError: Error, CustomStringConvertible {
    /// What was being searched for
    let name: String
    /// All errors encountered during the search
    let underlyingErrors: [Error]
    /// Identifier for finding the AX tree dump in the log file, if one was produced
    let dumpID: String?

    var description: String {
        var desc = "\(name) not found"
        if !underlyingErrors.isEmpty {
            desc += " — underlying: " + underlyingErrors.map(String.init(describing:)).joined(separator: "; ")
        }
        if let dumpID {
            desc += " (AX dump ID: \(dumpID))"
        }
        return desc
    }
}

/// MessagesAppElements contains all the fetching code (with retry) for `Accessibility.Element`s that MessagesController uses
/// aim to reduce side effects (like calling actions) here
@available(macOS 11, *)
final class MessagesAppElements {
    static func isMessageContainerCell(_ element: Accessibility.Element) throws -> Bool {
        let containsReactPrefix: ([Accessibility.Action]) -> Bool = { actions in
            actions.contains {
                $0.name.value.hasPrefix("Name:\(LocalizedStrings.react)")
            }
        }
        
        return try containsReactPrefix(element.children[0].supportedActions())
    }

    static func messageContainerCells(in tv: Accessibility.Element) throws -> [Accessibility.Element] {
        try tv.children().lazy.filter { (try? Self.isMessageContainerCell($0)) ?? false }
    }

    static func firstMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        try messageContainerCells(in: tv).first?.children[0]
    }

    static func firstSelectedMessageCell(in tv: Accessibility.Element) throws -> Accessibility.Element? {
        // selectedChildren wont work here
        // tv.children().first { (try? $0.selectedChildren[0]) != nil }?.children[0]
        try tv.children().first { (try? $0.children[0].isSelected()) == true }?.children[0]
    }

    private let runningApp: NSRunningApplication

    let app: Accessibility.Element

    private var cachedMainWindow: Accessibility.Element?

    init(runningApp: NSRunningApplication) {
        self.runningApp = runningApp
        app = Accessibility.Element(pid: runningApp.processIdentifier)
    }

    /// Search for an element by name, capturing underlying errors instead of swallowing them.
    /// - Parameters:
    ///   - name: Human-readable name of the element being searched for (used in the error message)
    ///   - dumpOnError: If true, dumps the AX tree from `root` into the log when the element is not found
    ///   - root: The element to dump from on failure. Defaults to `app`.
    ///   - search: Closure that performs the actual lookup. Return `nil` or throw to indicate not found.
    func find(
        _ name: String,
        logTime: Bool = false,
        dumpOnError: Bool = false,
        in root: Accessibility.Element? = nil,
        _ search: () throws -> Accessibility.Element?
    ) throws -> Accessibility.Element {
        let startTime = logTime ? Date() : nil
        
        defer {
            if let startTime {
                log.debug("\(name) took \(startTime.timeIntervalSinceNow * -1000)ms")
            }
        }

        var errors: [Error] = []
        do {
            if let result = try search() {
                return result
            }
        } catch {
            errors.append(error)
        }

        var dumpID: String?
        if dumpOnError {
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            dumpID = id
            do {
                var buffer = ""
                try (root ?? app).dumpXML(to: &buffer, maxDepth: 10, excludingPII: true, includeActions: false, includeSections: true)
                log.error("[\(id)] AX dump for \(name):\n\(buffer)")
            } catch {
                log.error("[\(id)] failed to dump AX tree for \(name): \(error)")
                errors.append(error)
            }
        }

        throw ElementSearchError(name: name, underlyingErrors: errors, dumpID: dumpID)
    }

    var allWindows: [Accessibility.Element] { // takes ~0ms
        get {
            // after a window is moved to the new space, AX doesn't list the window in appWindows or children
            (((try? app.appWindows()) ?? []) + [try? app.appMainWindow(), try? app.appFocusedWindow()]).compactMap { $0 }
        }
    }

    private static func getSectionObjects(window: Accessibility.Element) throws -> LazyMapCollection<LazyFilterSequence<LazyMapSequence<LazySequence<[[String: CFTypeRef]]>.Elements, Accessibility.Element?>>, Accessibility.Element> {
        try window.sections().lazy.compactMap { $0["SectionObject"].flatMap { Accessibility.Element(erased: $0) } }
    }

    private static func getConversationList(window: Accessibility.Element, useFastPath: Bool) -> Accessibility.Element? {
        if useFastPath, let cl = try? getSectionObjects(window: window).first(where: { (try? $0.identifier()) == "ConversationList" }) { return cl }
        if let cl = window.recursivelyFindChild(withID: "ConversationList") { return cl }
        return nil
    }

    private static func getCKConversationListCollectionView(window: Accessibility.Element) -> Accessibility.Element? {
        window.recursivelyFindChild(withID: "CKConversationListCollectionView")
    }

    func isMainWindow(window: Accessibility.Element) -> Bool {
        // note: doing these are unreliable
        // 1. detecting presence of AXSplitter
        // 2. using getConversationList with useFastPath=true
        Self.getConversationList(window: window, useFastPath: false) != nil || Self.getCKConversationListCollectionView(window: window) != nil
    }

    func getMainWindow() -> Accessibility.Element? { // takes ~24ms
        let startTime = Date()
        defer { log.debug("getMainWindow took \(startTime.timeIntervalSinceNow * -1000)ms") }
        return allWindows.first(where: isMainWindow)
    }

    private func isPromptVisibleInMessagesApp() -> Bool {
        allWindows.contains(where: { (try? $0.windowCloseButton().isEnabled()) == false })
    }
    
    // TODO: move to extension method on ax element
    private func dismissAnyPresentedSheet() throws {
        // TODO: a sheet can be potentially "primed" to appear but not actually appear until the window is actually created and _focused_ for whatever
        // TODO: reason. eg this code path can repeatedly fail (such as after being automatically launched by swiftserver) until the user clicks on the app, which then actually causes the
        // TODO: sheet to appear and the automated close to work.
        let mainWindow = try app.appMainWindow()
        guard let sheet = mainWindow.firstChild(withRole: \.sheet) else {
            log.debug("(found no sheet to dismiss)")
            return
        }
        
        let startTime = Date()
        guard let okButton = sheet.recursiveChildren().lazy.first(where: { child in
            let description = try? child.localizedDescription()
            return description == LocalizedStrings.dismissButtonLabel || description == LocalizedStrings.ok
        }) else {
            log.debug("found a sheet, but no OK button within it to dismiss (took \(startTime.elapsedMilliseconds)ms)")
            return
        }
        log.debug("found OK button within sheet, going to press it (took \(startTime.elapsedMilliseconds)ms)")
        do {
            try okButton.press()
        } catch {
            log.error("couldn't press OK button: \(error)")
        }
    }

    var _mainWindowReally: Accessibility.Element {
        get throws {
            if let cached = cachedMainWindow, cached.isFrameValid {
                return cached
            }
            let mainWindow = try retry(withTimeout: 5, interval: 0.2) { () throws -> Accessibility.Element in
                try getMainWindow().orThrow(ErrorMessage("Could not get main Messages window"))
            } onError: { attempt, _ in
                if attempt == 0 {
                    log.notice("mainWindow: using compose deep link to try to get main window")
                    try MessagesController.openDeepLink(MessagesDeepLink.compose.url())
                } else if attempt == 1 {
                    if self.isPromptVisibleInMessagesApp() {
                        log.notice("mainWindow: some prompts are visible, attempting to reset")
                        Defaults.resetPrompts()
                    }
                } else if attempt == 2 {
                    if self.isPromptVisibleInMessagesApp() {
                        log.error("mainWindow: some prompts are still visible, force terminating")
                        // regular terminate wont work since all window close buttons are disabled
                        self.runningApp.forceTerminate()
                        // this should invalidate the MessagesController
                    }
                } else if attempt > 3 {
                    do {
                       try self.dismissAnyPresentedSheet()
                    } catch {
                        log.error("couldn't try dismissing any presented sheet: \(error)")
                    }
                }
            }
//            try? MessagesController.resizeWindowToMaxHeight(mainWindow)
            // clearCachedElements()
            cachedMainWindow = mainWindow
            return mainWindow
        }
    }
    
    private var lastDumpedApplicationTree: Date?
    
    private func dumpAndLogApplicationTree() throws {
        var buffer = ""
        // 10 should be plenty
        try app.dumpXML(to: &buffer, maxDepth: 10, excludingPII: true, includeActions: false, includeSections: true)
        log.info("\(buffer)")
    }
    
    private func dumpAndLogApplicationTreeIfNeeded() throws {
        if let lastDumpedApplicationTree {
            guard lastDumpedApplicationTree.timeIntervalSinceNow * -1 >= 60 else {
                log.debug("not dumping application tree as it was dumped less than a minute ago")
                return
            }
        }

        defer { lastDumpedApplicationTree = Date() }
        try dumpAndLogApplicationTree()
    }
    
    var mainWindow: Accessibility.Element {
        get throws {
            do {
                return try _mainWindowReally
            } catch {
                do {
                    try dumpAndLogApplicationTreeIfNeeded()
                } catch {
                    log.error("couldn't dump application tree: \(String(describing: error))")
                }
                throw error
            }
        }
    }

    var conversationsList: Accessibility.Element { // takes ~34ms
        get throws {
            // if let cached = cachedConversationsList {
            //     return cached
            // }
            let startTime = Date()
            defer { log.debug("conversationsList took \(startTime.timeIntervalSinceNow * -1000)ms") }
            let cl = try retry(withTimeout: 1, interval: 0.1) {
                try Self.getConversationList(window: mainWindow, useFastPath: true).orThrow(ErrorMessage("ConversationList not found"))
            } onError: { _, _ in
                let searchField = try self.searchField
                log.error("fetching ConversationList errored, calling searchField.cancel")
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
            try Self.getSectionObjects(window: mainWindow)
        }
    }


    var selectedThreadCell: Accessibility.Element? {
        get {
            try? conversationsList.selectedChildren[0]
        }
    }

    private func getTranscriptView(replyTranscript: Bool) throws -> Accessibility.Element {
        let startTime = Date()
        defer { log.debug("getTranscriptView(replyTranscript: \(replyTranscript)) took \(startTime.timeIntervalSinceNow * -1000)ms") }

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
        if let tv = try? mainWindowSections.first(where: predicate) { return tv }
        // takes ~19ms
        if let tv = try? mainWindow.recursiveChildren().lazy.first(where: predicate) { return tv }
        throw ErrorMessage("TranscriptCollectionView(replyTranscript: \(replyTranscript)) not found")
    }

    var transcriptView: Accessibility.Element {
        get throws {
            try getTranscriptView(replyTranscript: false)
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

    var messageBodyField: Accessibility.Element {
        get throws {
            let startTime = Date()
            defer { log.debug("messageBodyField took \(startTime.timeIntervalSinceNow * -1000)ms") }
            var alternate = false
            return try retry(withTimeout: 1.5, interval: 0.1) {
                alternate
                    ? try mainWindow.recursivelyFindChild(withID: "messageBodyField").orThrow(ErrorMessage("messageBodyField not found"))
                    : try mainWindowSections.first { (try? $0.identifier()) == "messageBodyField" }.orThrow(ErrorMessage("messageBodyField not found")) // not present when compose cell is selected
            } onError: { attempt, _ in
                alternate = attempt % 2 == 0
            }
        }
    }

    var searchField: Accessibility.Element {
        get throws {
            let startTime = Date()
            defer { log.debug("searchField took \(startTime.timeIntervalSinceNow * -1000)ms") }
            return try retry(withTimeout: 1, interval: 0.1) {
                let CKConversationListCollectionView = try Self.getCKConversationListCollectionView(window: mainWindow)
                    .orThrow(ErrorMessage("CKConversationListCollectionView not found"))
                return try CKConversationListCollectionView.children().first { (try? $0.subrole()) == Accessibility.Subrole.searchField }
                    .orThrow(ErrorMessage("searchField not found"))
            }
        }
    }

    var iOSContentGroup: Accessibility.Element { // className=UINSSceneView
        get throws {
            try find("iOSContentGroup") {
                try mainWindow.children()
                    .first(where: { (try? $0.subrole()) == "iOSContentGroup" && (try? $0.role()) == NSAccessibility.Role.group.rawValue })
            }
        }
    }

    var iOSContentGroupFirstChild: Accessibility.Element { // className= CKUIWindow_60754894 or CKPresentationControllerWindow (when reactions are open)
        get throws {
            try find("iOSContentGroupFirstChild", logTime: true) {
                try iOSContentGroup.children[0]
            }
        }
    }

    var addCustomEmojiReactionButton: Accessibility.Element {
        get throws {
            // identifiers of the _children of_ iOSContentGroupFirstChild as of 15.3:
            // ([String?]) 5 values {
            //   [0] = "TapbackPickerCollectionView"
            //   [1] = "Sticker"
            //   [2] = "Sticker"
            //   [3] = "Sticker"
            //   [4] = nil <-- this is the add custom emoji reaction button
            // }

            // find element with class name `ChatKit.TapbackPickerEmojiTailView`
            // its localizedDescription is "Add custom emoji reaction", but it's likely different for non-en_US locales
            let elem = try (try? iOSContentGroupFirstChild)?.children().first {
                (try? $0.identifier()) == nil && (try? $0.role()) == "AXButton"
            }
            return try elem.orThrow(ErrorMessage("couldn't find button to add custom emoji reaction"))
        }
    }

    // TODO: leverage to implement sticker avoidance (DESK-7141)
#if false
    var customEmojiPopoverCharacters: [Accessibility.Element] {
        get throws {
            let popover = try popover
            // the CPKCharactersTableView within NSScrollView (within _NSPopoverWindow)
            let table = try popover.recursiveChildren().lazy.first(where: { (try? $0.subrole() == "table") ?? false })
                .orThrow(ErrorMessage("couldn't find table view containing emoji results"))
        }
    }
#endif

    /// the first popover in the main window
    var popover: Accessibility.Element {
        get throws {
            try find("popover") {
                try mainWindow
                    .recursiveChildren()
                    .lazy
                    .first(where: { (try? $0.roleDescription() == "popover") ?? false })
            }
        }
    }

    /// the first search field within the first popover in the main window
    var searchFieldWithinPopover: Accessibility.Element {
        get throws {
            try find("searchFieldWithinPopover") {
                try popover
                    .recursiveChildren().lazy.first(where: { (try? $0.roleDescription() == "search text field") ?? false })
            }
        }
    }

    var splitter: Accessibility.Element {
        get throws {
            try find("splitter", logTime: true) {
                try iOSContentGroupFirstChild.children().first(where: { (try? $0.role()) == Accessibility.Role.splitter })
            }
        }
    }

    var reactionsView: Accessibility.Element {
        get throws {
            let startTime = Date()
            defer { log.debug("reactionsView took \(startTime.timeIntervalSinceNow * -1000)ms") }
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
            let startTime = Date()
            defer { log.debug("reactButtons took \(startTime.timeIntervalSinceNow * -1000)ms") }
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
            guard let buttons = try? reactionsView.children().filter({ (try? $0.role()) == Accessibility.Role.button }) else {
                throw ErrorMessage("reactButtons not found")
            }
            return buttons
        }
    }

    var tapbackPickerCollectionView: Accessibility.Element {
        get throws {
            let startTime = Date()
            defer { log.debug("tapbackPickerCollectionView took \(startTime.timeIntervalSinceNow * -1000)ms") }
            guard let element = try? reactionsView.children().first(where: { (try? $0.identifier()) == "TapbackPickerCollectionView" }) else {
                throw ErrorMessage("tapbackPickerCollectionView not found")
            }
            return element
        }
    }

    var alertSheet: Accessibility.Element {
        get throws {
            try find("alertSheet") {
                try mainWindow.children().first(where: { try $0.role() == Accessibility.Role.sheet })
            }
        }
    }

    var alertSheetDeleteButton: Accessibility.Element {
        get throws {
            try find("alertSheetDeleteButton") {
                try alertSheet.children().first(where: { try $0.role() == Accessibility.Role.button })
            }
        }
    }

    var notifyAnywayButton: Accessibility.Element {
        get throws {
            let startTime = Date()
            defer { log.debug("notifyAnywayButton took \(startTime.timeIntervalSinceNow * -1000)ms") }
            let tv = try transcriptView
            let count = try tv.children.count()
            return try transcriptView.children(range: (count - 2)..<count).first(where: {
                let child = try $0.children[0]
                return (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway && (try? child.role()) == Accessibility.Role.button
            }).orThrow(ErrorMessage("notifyAnywayButton not found"))
        }
    }

    var editableMessageField: Accessibility.Element {
        get throws {
            let editingConfirmButton = try iOSContentGroup.recursiveChildren().lazy.first(where: {
                (try? $0.localizedDescription()) == LocalizedStrings.editingConfirm
            }).orThrow(ErrorMessage("editingConfirmButton not found"))
            return try editingConfirmButton.parent().recursiveChildren().lazy.first(where: {
                (try? $0.role()) == Accessibility.Role.textField
            }).orThrow(ErrorMessage("editableMessageField not found"))
        }
    }

    var menu: Accessibility.Element {
        get throws {
            try retry(withTimeout: 2, interval: 0.1) {
                try iOSContentGroup.children().first { try $0.role() == Accessibility.Role.menu }
                    .orThrow(ErrorMessage("menu not found"))
            }
        }
    }

    var menuEditItem: Accessibility.Element {
        get throws {
            try retry(withTimeout: 1, interval: 0.05) {
                try menu.children().first { (try? $0.identifier()) == "edit" }
                    .orThrow(ErrorMessage("Couldn't find \"Edit\" menu item; messages are only editable for 15 minutes after sending"))
            }
        }
    }

    var cancelEditButton: Accessibility.Element {
        get throws {
            try find("cancelEditButton") {
                try iOSContentGroupFirstChild.recursiveChildren()
                    .first(where: {
                        (try? $0.localizedDescription()) == LocalizedStrings.editingReject
                    })
            }
        }
    }

    var toFieldPopupButton: Accessibility.Element {
        get throws {
            try find("toFieldPopupButton") {
                try iOSContentGroup.children[0].children().first { try $0.role() == Accessibility.Role.popUpButton }
            }
        }
    }
}
