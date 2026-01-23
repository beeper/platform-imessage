import AccessibilityControl
import AppKit
import ArgumentParser
import BetterSwiftAXAdditions
import Foundation
import Logging
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "reaction-test")

private func bootstrap(logLevel: Logger.Level = .info) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = logLevel
        return handler
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}

// Simplified MessagesAppElements for testing
class TestMessagesElements {
    let app: Accessibility.Element
    let runningApp: NSRunningApplication

    init(runningApp: NSRunningApplication) {
        self.runningApp = runningApp
        self.app = Accessibility.Element(pid: runningApp.processIdentifier)
    }

    var mainWindow: Accessibility.Element {
        get throws {
            guard let window = try app.appWindows().first(where: { window in
                // Main window has conversation list
                window.recursivelyFindChild(withID: "ConversationList") != nil ||
                window.recursivelyFindChild(withID: "CKConversationListCollectionView") != nil
            }) else {
                throw ErrorMessage("Could not find main Messages window")
            }
            return window
        }
    }

    func getTranscriptView(replyTranscript: Bool) throws -> Accessibility.Element {
        let window = try mainWindow

        // On Tahoe: reply transcript desc = "Reply transcript", main transcript desc = "Messages"
        // On pre-Tahoe: reply transcript desc = "Reply", main transcript desc = "Messages"
        func isReplyTranscript(_ desc: String?) -> Bool {
            desc == "Reply transcript" || desc == "Reply"
        }

        func search(_ element: Accessibility.Element, depth: Int = 0) -> Accessibility.Element? {
            guard depth < 15 else { return nil }

            let id = try? element.identifier()
            let desc = try? element.localizedDescription()

            if id == "TranscriptCollectionView" {
                let isReply = isReplyTranscript(desc)
                if replyTranscript == isReply {
                    return element
                }
            }

            for child in (try? element.children()) ?? [] {
                if let found = search(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        guard let found = search(window) else {
            throw ErrorMessage("TranscriptCollectionView not found (replyTranscript=\(replyTranscript))")
        }
        return found
    }

    var transcriptView: Accessibility.Element {
        get throws { try getTranscriptView(replyTranscript: false) }
    }

    var replyTranscriptView: Accessibility.Element {
        get throws { try getTranscriptView(replyTranscript: true) }
    }

    var iOSContentGroup: Accessibility.Element {
        get throws {
            let window = try mainWindow
            guard let group = try window.children().first(where: {
                (try? $0.subrole()) == "iOSContentGroup" && (try? $0.role()) == "AXGroup"
            }) else {
                throw ErrorMessage("iOSContentGroup not found")
            }
            return group
        }
    }

    var reactionsView: Accessibility.Element {
        get throws {
            let group = try iOSContentGroup
            guard let first = try? group.children[0], (try? first.children.count()) ?? 0 > 0 else {
                throw ErrorMessage("reactionsView not found")
            }
            return first
        }
    }

    var tapbackPickerCollectionView: Accessibility.Element {
        get throws {
            let view = try reactionsView
            guard let picker = try view.children().first(where: { (try? $0.identifier()) == "TapbackPickerCollectionView" }) else {
                throw ErrorMessage("TapbackPickerCollectionView not found")
            }
            return picker
        }
    }

    var menu: Accessibility.Element {
        get throws {
            // Menus are direct children of the app
            for child in (try? app.children()) ?? [] {
                let role = try? child.role()
                if role == "AXMenu" {
                    return child
                }
            }

            // Also check if menu is a window
            for window in (try? app.appWindows()) ?? [] {
                let role = try? window.role()
                let subrole = try? window.subrole()
                if role == "AXMenu" || subrole == "AXMenu" {
                    return window
                }
            }

            // Check main window children
            if let mainWin = try? mainWindow {
                for child in (try? mainWin.children()) ?? [] {
                    let role = try? child.role()
                    if role == "AXMenu" {
                        return child
                    }
                }
            }

            throw ErrorMessage("No menu found")
        }
    }
}

@main
struct ReactionTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Test reaction flow on Messages.app"
    )

    @Option(name: .long, help: "Log level")
    var logLevel: Logger.Level = .info

    @Option(name: .shortAndLong, help: "Message GUID to react to")
    var guid: String?

    @Option(name: .shortAndLong, help: "Reaction: heart, thumbsUp, thumbsDown, haha, exclamation, question")
    var reaction: String = "heart"

    @Flag(name: .long, help: "Message is in a reply overlay")
    var overlay: Bool = false

    @Flag(name: .long, help: "Use context menu instead of custom AX action")
    var useMenu: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() throws {
        bootstrap(logLevel: verbose ? .trace : logLevel)

        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
            throw ErrorMessage("Messages.app is not running")
        }

        let elements = TestMessagesElements(runningApp: runningApp)
        log.info("Connected to Messages.app (pid: \(runningApp.processIdentifier))")

        if let guid {
            log.info("Opening deep link for message: \(guid), overlay: \(overlay)")
            let url = URL(string: "imessage:open?message-guid=\(guid)&overlay=\(overlay ? 1 : 0)")!
            NSWorkspace.shared.open(url)
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Step 1: Find transcript view
        log.info("Step 1: Finding transcript view (overlay=\(overlay))...")
        let transcriptView: Accessibility.Element
        if overlay {
            transcriptView = try elements.replyTranscriptView
            let desc = (try? transcriptView.localizedDescription()) ?? "<no desc>"
            log.info("Found REPLY transcript view (desc: '\(desc)')")
        } else {
            transcriptView = try elements.transcriptView
            let desc = (try? transcriptView.localizedDescription()) ?? "<no desc>"
            log.info("Found MAIN transcript view (desc: '\(desc)')")
        }

        // Step 2: Find message cells
        log.info("Step 2: Finding message cells...")
        let cells = try transcriptView.children()
        log.info("Found \(cells.count) children in transcript")

        var selectedCell: Accessibility.Element?
        var firstMessageCell: Accessibility.Element?

        for (i, container) in cells.enumerated() {
            guard let cell = try? container.children[0] else { continue }

            let actions = (try? cell.supportedActions()) ?? []
            let actionNames = actions.map { $0.name.value }

            // Check for react action - might be "Name:React" or contain "React" or "Tapback"
            let hasReactAction = actionNames.contains { $0.contains("React") || $0.contains("Tapback") || $0.contains("heart") }

            // Also check if it's a message by looking for Name: prefixed actions
            let hasNameAction = actionNames.contains { $0.hasPrefix("Name:") }

            if (hasReactAction || hasNameAction) && firstMessageCell == nil {
                firstMessageCell = cell
            }

            let isSelected = (try? cell.isSelected()) == true
            let desc = (try? cell.localizedDescription()) ?? ""
            let id = (try? cell.identifier()) ?? ""

            if verbose || isSelected || i >= cells.count - 5 {
                let marker = isSelected ? ">>> SELECTED" : "   "
                log.info("\(marker) Cell[\(i)]: id='\(id)' desc='\(desc.prefix(30))'")
                if verbose || isSelected {
                    for action in actionNames where action.hasPrefix("Name:") || action.contains("React") {
                        log.info("      action: \(action)")
                    }
                }
            }

            if isSelected && (hasReactAction || hasNameAction) {
                selectedCell = cell
            }
        }

        // Use first message cell if none selected (for overlay mode)
        let targetCell: Accessibility.Element
        if let selected = selectedCell {
            targetCell = selected
            log.info("Using selected message cell")
        } else if let first = firstMessageCell {
            targetCell = first
            log.info("No selected cell, using first message cell with actions")
        } else {
            log.error("No message cell found!")
            log.info("Tip: Select a message in Messages.app first, or use --guid")

            // Debug: show all actions on last few cells
            log.info("Debug: showing actions on last few cells...")
            for i in max(0, cells.count - 3)..<cells.count {
                if let cell = try? cells[i].children[0] {
                    let actions = (try? cell.supportedActions().map { $0.name.value }) ?? []
                    log.info("  Cell[\(i)] actions: \(actions)")
                }
            }

            throw ErrorMessage("No message cell found")
        }

        // Step 3: List available actions
        log.info("Step 3: Getting available actions on message cell...")
        let actions = try targetCell.supportedActions()
        for action in actions {
            let name = action.name.value
            if name.contains("Name:") || verbose {
                log.info("  Action: \(name)")
            }
        }

        if useMenu {
            log.info("Step 4: Using context menu approach...")
            try reactViaContextMenu(elements: elements, cell: targetCell, reaction: reaction)
        } else {
            log.info("Step 4: Using custom AX action approach...")
            try reactViaCustomAction(elements: elements, cell: targetCell, reaction: reaction)
        }

        log.info("Done!")
    }

    func reactViaCustomAction(elements: TestMessagesElements, cell: Accessibility.Element, reaction: String) throws {
        let actions = try cell.supportedActions()
        let actionNames = actions.map { $0.name.value }

        // On Tahoe: Individual tapback actions are exposed directly (Name:Heart, Name:Thumbs up, etc.)
        // On pre-Tahoe: There's a single "Name:React" action that opens the picker

        let reactionActionName = reactionNameToActionName(reaction)
        log.info("Looking for direct reaction action: '\(reactionActionName)'")

        if let directAction = actions.first(where: { $0.name.value.hasPrefix("Name:\(reactionActionName)") }) {
            // Tahoe path: Direct action
            log.info("Found direct reaction action (Tahoe style): \(directAction.name.value.prefix(30))")
            log.info("Invoking direct action...")
            try directAction()
            log.info("✅ Direct reaction action invoked!")
            return
        }

        // Pre-Tahoe path: Use React action to open picker
        let reactAction = actions.first { $0.name.value.hasPrefix("Name:React") }
        guard let reactAction else {
            log.error("Neither direct reaction action nor React action found")
            log.info("Available Name: actions:")
            for name in actionNames where name.hasPrefix("Name:") {
                log.info("  \(name.prefix(50))")
            }
            throw ErrorMessage("No reaction action found")
        }

        log.info("Found React action (pre-Tahoe style): \(reactAction.name.value)")
        log.info("Triggering React action...")
        try reactAction()

        log.info("Waiting for tapback picker (0.75s)...")
        Thread.sleep(forTimeInterval: 0.75)

        // Find tapback picker
        log.info("Looking for TapbackPickerCollectionView...")
        let picker = try elements.tapbackPickerCollectionView
        let buttons = try picker.children()

        log.info("Tapback picker has \(buttons.count) buttons:")
        for (i, btn) in buttons.enumerated() {
            let id = (try? btn.identifier()) ?? "<no id>"
            let selected = (try? btn.isSelected()) ?? false
            let desc = (try? btn.localizedDescription()) ?? ""
            log.info("  [\(i)] id='\(id)' selected=\(selected) desc='\(desc)'")
        }

        // Find and click reaction button
        let reactionId = reactionNameToId(reaction)
        guard let targetBtn = buttons.first(where: { (try? $0.identifier()) == reactionId }) else {
            let available = buttons.compactMap { try? $0.identifier() }
            throw ErrorMessage("Reaction button '\(reactionId)' not found. Available: \(available)")
        }

        let beforeSelected = (try? targetBtn.isSelected()) ?? false
        log.info("Target button '\(reactionId)' isSelected=\(beforeSelected)")
        log.info("Pressing button...")

        try targetBtn.press()

        log.info("Waiting (0.3s)...")
        Thread.sleep(forTimeInterval: 0.3)

        let afterSelected = (try? targetBtn.isSelected()) ?? false
        log.info("After press: isSelected=\(afterSelected)")

        if afterSelected == beforeSelected {
            log.warning("⚠️ isSelected didn't change!")
            log.warning("This could indicate the reaction didn't apply, or isSelected is broken on Tahoe.")
        } else if afterSelected {
            log.info("✅ Reaction applied!")
        } else {
            log.info("✅ Reaction removed!")
        }
    }

    func reactionNameToActionName(_ name: String) -> String {
        // Maps reaction name to Tahoe AX action name
        switch name.lowercased() {
        case "heart": return "Heart"
        case "thumbsup", "like": return "Thumbs up"
        case "thumbsdown", "dislike": return "Thumbs down"
        case "haha", "laugh": return "Ha ha!"
        case "exclamation", "!!": return "Exclamation mark"
        case "question", "?": return "Question mark"
        default: return name
        }
    }

    func reactViaContextMenu(elements: TestMessagesElements, cell: Accessibility.Element, reaction: String) throws {
        log.info("Activating Messages.app (required for context menus)...")
        elements.runningApp.activate()
        Thread.sleep(forTimeInterval: 0.5)

        log.info("Getting parent container of cell...")
        let parentContainer = try cell.parent()
        let parentRole = (try? parentContainer.role()) ?? "?"
        let parentId = (try? parentContainer.identifier()) ?? "?"
        let parentDesc = (try? parentContainer.localizedDescription()) ?? "?"
        log.info("Parent container: role=\(parentRole) id=\(parentId) desc='\(parentDesc.prefix(30))'")

        // Check if showMenu is available on parent
        let parentActions = (try? parentContainer.supportedActions().map { $0.name.value }) ?? []
        log.info("Parent actions: \(parentActions.prefix(5))...")

        log.info("Scrolling parent into view...")
        try parentContainer.scrollToVisible()
        Thread.sleep(forTimeInterval: 0.3)

        log.info("Showing context menu on PARENT (not cell)...")
        try parentContainer.showMenu()

        log.info("Waiting for menu (0.5s)...")
        Thread.sleep(forTimeInterval: 0.5)

        log.info("Looking for menu...")
        let menu = try findContextMenu(elements: elements)
        let menuItems = try menu.children()

        log.info("Menu has \(menuItems.count) items:")
        for (i, item) in menuItems.enumerated() {
            let title = (try? item.title()) ?? "<no title>"
            log.info("  [\(i)] '\(title)'")
        }

        guard let tapbackItem = menuItems.first(where: { (try? $0.title()) == "Tapback" }) else {
            throw ErrorMessage("Tapback menu item not found")
        }

        log.info("Opening Tapback submenu...")
        try tapbackItem.press()

        log.info("Waiting for submenu (0.2s)...")
        Thread.sleep(forTimeInterval: 0.2)

        guard let submenu = try? tapbackItem.children().first else {
            throw ErrorMessage("Tapback submenu not found")
        }

        let submenuItems = try submenu.children()
        log.info("Tapback submenu has \(submenuItems.count) items:")
        for (i, item) in submenuItems.enumerated() {
            let title = (try? item.title()) ?? "<no title>"
            log.info("  [\(i)] '\(title)'")
        }

        let reactionIndex = reactionNameToIndex(reaction)
        guard submenuItems.indices.contains(reactionIndex) else {
            throw ErrorMessage("Reaction index \(reactionIndex) out of bounds")
        }

        log.info("Clicking reaction at index \(reactionIndex)...")
        try submenuItems[reactionIndex].press()

        log.info("Waiting (0.5s)...")
        Thread.sleep(forTimeInterval: 0.5)

        log.info("✅ Reaction applied via context menu!")
    }

    func findContextMenu(elements: TestMessagesElements) throws -> Accessibility.Element {
        log.info("Searching for context menu...")

        // Debug: dump app children
        log.info("App children:")
        for (i, child) in ((try? elements.app.children()) ?? []).enumerated() {
            let role = (try? child.role()) ?? "<no role>"
            let title = (try? child.title()) ?? ""
            log.info("  [\(i)] role=\(role) title='\(title)'")
            if role == "AXMenu" {
                log.info("Found menu as app child at index \(i)")
                return child
            }
        }

        // Check main window's first group (iOSContentGroup) children
        if let window = try? elements.mainWindow {
            log.info("Main window children:")
            for (i, child) in ((try? window.children()) ?? []).enumerated() {
                let role = (try? child.role()) ?? "<no role>"
                let subrole = (try? child.subrole()) ?? ""
                log.info("  [\(i)] role=\(role) subrole=\(subrole)")

                // Check children of this element too
                for (j, subchild) in ((try? child.children()) ?? []).enumerated() {
                    let subRole = (try? subchild.role()) ?? "<no role>"
                    if subRole == "AXMenu" {
                        log.info("Found menu at window[\(i)][\(j)]")
                        return subchild
                    }
                }
            }
        }

        // Deep search in iOSContentGroup
        if let iOSGroup = try? elements.iOSContentGroup {
            log.info("iOSContentGroup children:")
            for (i, child) in ((try? iOSGroup.children()) ?? []).enumerated() {
                let role = (try? child.role()) ?? "<no role>"
                log.info("  [\(i)] role=\(role)")
                if role == "AXMenu" {
                    log.info("Found menu in iOSContentGroup at index \(i)")
                    return child
                }
            }
        }

        throw ErrorMessage("Context menu not found")
    }

    func reactionNameToId(_ name: String) -> String {
        switch name.lowercased() {
        case "heart": return "heart"
        case "thumbsup", "like": return "thumbsUp"
        case "thumbsdown", "dislike": return "thumbsDown"
        case "haha", "laugh": return "ha"
        case "exclamation", "!!": return "exclamation"
        case "question", "?": return "question"
        default: return name
        }
    }

    func reactionNameToIndex(_ name: String) -> Int {
        switch name.lowercased() {
        case "heart": return 0
        case "thumbsup", "like": return 1
        case "thumbsdown", "dislike": return 2
        case "haha", "laugh": return 3
        case "exclamation", "!!": return 4
        case "question", "?": return 5
        default: return 0
        }
    }
}
