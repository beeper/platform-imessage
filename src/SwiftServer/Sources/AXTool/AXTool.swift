import AccessibilityControl
import AppKit
import ArgumentParser
import BetterSwiftAXAdditions
import Foundation
import Logging
import SwiftServerFoundation

private func bootstrap(logLevel: Logger.Level = .trace) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = logLevel
        return handler
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}

@main
struct AXTool: ParsableCommand {
    struct Options: ParsableArguments {
        @Option(name: .long, help: "Specify the log level.")
        var logLevel: Logger.Level = .trace
    }

    static let configuration = CommandConfiguration(
        abstract: "Exercise functionality in BetterSwiftAX and friends.",
        subcommands: [Dump.self, React.self],
    )

    mutating func run() throws {}
}

extension AXTool {
    struct React: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Test reaction flow on Messages.app"
        )

        @OptionGroup var options: AXTool.Options

        @Option(name: .shortAndLong, help: "Message GUID to react to")
        var guid: String?

        @Option(name: .shortAndLong, help: "Reaction: heart, thumbsUp, thumbsDown, haha, exclamation, question")
        var reaction: String = "heart"

        @Flag(name: .long, help: "Message is in a reply overlay")
        var overlay: Bool = false

        @Flag(name: .long, help: "Use context menu instead of custom AX action")
        var useMenu: Bool = false

        mutating func run() throws {
            bootstrap(logLevel: options.logLevel)
            let log = Logger(label: "axtool.react")

            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
                Self.exit(withError: ErrorMessage("Messages.app is not running"))
            }

            let app = Accessibility.Element(pid: runningApp.processIdentifier)

            if let guid {
                log.info("Opening deep link for message: \(guid), overlay: \(overlay)")
                let url = URL(string: "imessage:open?message-guid=\(guid)&overlay=\(overlay ? 1 : 0)")!
                NSWorkspace.shared.open(url)
                Thread.sleep(forTimeInterval: 1.0)
            }

            log.info("Finding transcript view...")
            let transcriptView: Accessibility.Element
            do {
                transcriptView = try findTranscriptView(app: app, replyTranscript: overlay)
                let desc = (try? transcriptView.localizedDescription()) ?? "<no desc>"
                log.info("Found transcript view with description: '\(desc)'")
            } catch {
                log.error("Failed to find transcript view: \(error)")
                log.info("Dumping window structure to help debug...")
                dumpWindowStructure(app: app, log: log)
                throw error
            }

            log.info("Finding message cells...")
            let cells = try transcriptView.children()
            log.info("Found \(cells.count) children in transcript")

            var messageCell: Accessibility.Element?
            for (i, cell) in cells.enumerated() {
                guard let firstChild = try? cell.children[0] else { continue }
                let isSelected = (try? firstChild.isSelected()) == true
                let desc = (try? firstChild.localizedDescription()) ?? ""
                if isSelected {
                    log.info("Cell[\(i)]: SELECTED - \(desc.prefix(50))")
                    messageCell = firstChild
                } else if i >= cells.count - 3 {
                    log.debug("Cell[\(i)]: \(desc.prefix(50))")
                }
            }

            guard let cell = messageCell else {
                log.error("No selected message cell found")
                log.info("Tip: Select a message in Messages.app first, or use --guid")
                throw ErrorMessage("No selected message cell")
            }

            log.info("Getting available actions on message cell...")
            let actions = try cell.supportedActions()
            for action in actions {
                log.info("  Action: \(action.name.value)")
            }

            if useMenu {
                log.info("Using context menu approach...")
                try reactViaContextMenu(app: app, cell: cell, reaction: reaction, log: log)
            } else {
                log.info("Using custom AX action approach...")
                try reactViaCustomAction(app: app, cell: cell, reaction: reaction, log: log)
            }

            log.info("Done!")
        }

        func findTranscriptView(app: Accessibility.Element, replyTranscript: Bool) throws -> Accessibility.Element {
            let targetDesc = replyTranscript ? "Reply transcript" : "Messages"

            guard let mainWindow = try app.appWindows().first else {
                throw ErrorMessage("No windows found")
            }

            func search(_ element: Accessibility.Element, depth: Int = 0) throws -> Accessibility.Element? {
                guard depth < 15 else { return nil }

                let id = try? element.identifier()
                let desc = try? element.localizedDescription()

                if id == "TranscriptCollectionView" {
                    if replyTranscript {
                        // For reply transcript, accept "Reply" or "Reply transcript"
                        if desc == "Reply" || desc == "Reply transcript" {
                            return element
                        }
                    } else {
                        // For main transcript, accept "Messages"
                        if desc == "Messages" {
                            return element
                        }
                    }
                }

                for child in (try? element.children()) ?? [] {
                    if let found = try? search(child, depth: depth + 1) {
                        return found
                    }
                }
                return nil
            }

            if let found = try search(mainWindow) {
                return found
            }
            throw ErrorMessage("TranscriptCollectionView not found (looking for desc='\(targetDesc)')")
        }

        func dumpWindowStructure(app: Accessibility.Element, log: Logger) {
            let windows = (try? app.appWindows()) ?? []
            for (i, window) in windows.enumerated() {
                let title = (try? window.title()) ?? "<no title>"
                log.info("Window[\(i)]: \(title)")

                func dump(_ el: Accessibility.Element, indent: String, depth: Int) {
                    guard depth < 8 else { return }
                    let role = (try? el.role()) ?? "<no role>"
                    let id = (try? el.identifier()) ?? ""
                    let desc = (try? el.localizedDescription()) ?? ""
                    let idStr = id.isEmpty ? "" : " #\(id)"
                    let descStr = desc.isEmpty ? "" : " '\(desc.prefix(30))'"
                    log.info("\(indent)\(role)\(idStr)\(descStr)")

                    for child in (try? el.children()) ?? [] {
                        dump(child, indent: indent + "  ", depth: depth + 1)
                    }
                }
                dump(window, indent: "  ", depth: 0)
            }
        }

        func reactViaCustomAction(app: Accessibility.Element, cell: Accessibility.Element, reaction: String, log: Logger) throws {
            let reactAction = try cell.supportedActions().first { $0.name.value.hasPrefix("Name:React") }
            guard let reactAction else {
                throw ErrorMessage("React action not found on cell")
            }

            log.info("Triggering React action...")
            try reactAction()
            Thread.sleep(forTimeInterval: 0.75)

            log.info("Looking for tapback picker...")
            let picker = try findTapbackPicker(app: app)
            let buttons = try picker.children()

            log.info("Tapback picker has \(buttons.count) buttons:")
            for (i, btn) in buttons.enumerated() {
                let id = (try? btn.identifier()) ?? "<no id>"
                let selected = (try? btn.isSelected()) ?? false
                let desc = (try? btn.localizedDescription()) ?? ""
                log.info("  [\(i)] id=\(id) selected=\(selected) desc=\(desc)")
            }

            let reactionId = reactionNameToId(reaction)
            guard let targetBtn = buttons.first(where: { (try? $0.identifier()) == reactionId }) else {
                throw ErrorMessage("Reaction button '\(reactionId)' not found")
            }

            let beforeSelected = (try? targetBtn.isSelected()) ?? false
            log.info("Target button '\(reactionId)' isSelected=\(beforeSelected), pressing...")

            try targetBtn.press()
            Thread.sleep(forTimeInterval: 0.3)

            let afterSelected = (try? targetBtn.isSelected()) ?? false
            log.info("After press: isSelected=\(afterSelected)")

            if afterSelected == beforeSelected {
                log.warning("isSelected didn't change! This may indicate the reaction didn't apply.")
            }
        }

        func findTapbackPicker(app: Accessibility.Element) throws -> Accessibility.Element {
            guard let mainWindow = try app.appWindows().first else {
                throw ErrorMessage("No windows found")
            }

            func search(_ element: Accessibility.Element, depth: Int = 0) throws -> Accessibility.Element? {
                guard depth < 15 else { return nil }

                let id = try? element.identifier()
                if id == "TapbackPickerCollectionView" {
                    return element
                }

                for child in (try? element.children()) ?? [] {
                    if let found = try? search(child, depth: depth + 1) {
                        return found
                    }
                }
                return nil
            }

            if let found = try search(mainWindow) {
                return found
            }
            throw ErrorMessage("TapbackPickerCollectionView not found")
        }

        func reactViaContextMenu(app: Accessibility.Element, cell: Accessibility.Element, reaction: String, log: Logger) throws {
            log.info("Showing context menu on cell...")
            try cell.showMenu()
            Thread.sleep(forTimeInterval: 0.3)

            log.info("Looking for menu...")
            let menu = try findMenu(app: app)

            let menuItems = try menu.children()
            log.info("Menu has \(menuItems.count) items:")
            for (i, item) in menuItems.enumerated() {
                let title = (try? item.title()) ?? "<no title>"
                let id = (try? item.identifier()) ?? "<no id>"
                log.info("  [\(i)] '\(title)' id=\(id)")
            }

            guard let tapbackItem = menuItems.first(where: { (try? $0.title()) == "Tapback" }) else {
                throw ErrorMessage("Tapback menu item not found")
            }

            log.info("Opening Tapback submenu...")
            try tapbackItem.press()
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
            Thread.sleep(forTimeInterval: 0.5)
        }

        func findMenu(app: Accessibility.Element) throws -> Accessibility.Element {
            // Menus are usually direct children of the app, not inside windows
            for child in (try? app.children()) ?? [] {
                let role = try? child.role()
                if role == "AXMenu" {
                    return child
                }
            }

            // Also check windows
            for window in (try? app.appWindows()) ?? [] {
                let role = try? window.role()
                if role == "AXMenu" {
                    return window
                }
            }

            throw ErrorMessage("No menu found")
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
}

extension AXTool {
    struct Dump: ParsableCommand {
        @OptionGroup var options: AXTool.Options

        @Argument(help: "The bundle identifier of the app to target.")
        var bundleID = "com.apple.MobileSMS"

        @Flag(name: [.customShort("s"), .customLong("no-sections")], help: "Skips dumping sections.")
        var excludeSections = false

        @Flag(name: [.customLong("no-actions")], help: "Skips dumping actions.")
        var excludeActions = false

        @Option(name: [.customShort("x"), .customLong("exclude-role")], help: "Skips dumping UI elements with the given role.")
        var excludedRoles = [String]()

        @Option(name: [.customShort("a"), .customLong("exclude-attribute")], help: "Skips dumping the named UI element attribute.")
        var excludedAttributes = Array(XMLDumper.defaultExcludedAttributes)

        @Option(name: [.customShort("d"), .customLong("max-depth")], help: "Skips dumping elements surpassing the specified depth.")
        var maxDepth: Int? = nil

        @Flag(name: [.customShort("p"), .customLong("no-pii")], help: "Attempts to omit PII from the output.")
        var excludingPII = false

        mutating func run() throws {
            bootstrap(logLevel: options.logLevel)

            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                Self.exit(withError: ErrorMessage("Found no running applications with the bundle identifier \"\(bundleID)\"."))
            }
            let app = Accessibility.Element(pid: runningApp.processIdentifier)

            var output = ""
            print("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>", to: &output)

            try app.dumpXML(
                to: &output,
                maxDepth: maxDepth,
                excludingPII: excludingPII,
                excludingElementsWithRoles: Set(excludedRoles),
                excludingAttributes: Set(excludedAttributes),
                includeActions: !excludeActions,
                includeSections: !excludeSections,
            )
            print(output)
        }
    }
}
