import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit

extension AXDump {
    struct Find: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Find elements and optionally act on them",
            discussion: """
                Smart element finder with built-in actions. Finds elements by text content,
                role, identifier, or combinations thereof.

                SELECTORS:
                  "text"                  Find element containing "text" (title, value, or description)
                  --role Button "OK"      Find Button containing "OK"
                  --id searchField        Find element with identifier "searchField"
                  --role TextField        Find any TextField

                ACTIONS (performed on first match):
                  --click, -c             Click/press the element
                  --focus, -f             Focus the element
                  --type "text"           Set the element's value
                  --read, -r              Print the element's value
                  --custom, -C "name"     Perform a custom action (e.g., tapback reactions)

                EXAMPLES:
                  axdump find 710 "Save"                    Find "Save" button/text
                  axdump find 710 "Save" --click            Find and click "Save"
                  axdump find 710 --role Button "Cancel"    Find Button with "Cancel"
                  axdump find 710 --role TextField --focus  Focus first text field
                  axdump find 710 --id searchField --type "query"
                  axdump find 710 "File name" --read        Read value near "File name"
                  axdump find 710 --role MenuItem "Copy" -c Execute Copy menu item
                  axdump find 710 --all "Button"            Find ALL matching elements
                  axdump find 710 "hello" --id Sticker -C "Heart"   React with Heart
                  axdump find 710 "hello" --id Sticker -C "👍"      React with emoji
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Argument(help: "Text to search for (in title, value, description, or identifier)")
        var text: String?

        @Option(name: .long, help: "Filter by role (Button, TextField, MenuItem, etc.)")
        var role: String?

        @Option(name: .long, help: "Filter by identifier")
        var id: String?

        @Option(name: .long, help: "Filter by subrole")
        var subrole: String?

        @Flag(name: [.customShort("c"), .long], help: "Click/press the found element")
        var click: Bool = false

        @Flag(name: [.customShort("f"), .long], help: "Focus the found element")
        var focus: Bool = false

        @Option(name: [.customShort("t"), .long], help: "Type/set this value into the element")
        var type: String?

        @Flag(name: [.customShort("r"), .long], help: "Read and print the element's value")
        var read: Bool = false

        @Option(name: [.customShort("C"), .long], help: "Perform a custom action by name (e.g., 'Heart', 'Thumbs up')")
        var custom: String?

        @Flag(name: .long, help: "Find ALL matching elements (not just first)")
        var all: Bool = false

        @Option(name: [.customShort("n"), .long], help: "Select the Nth match (1-based, default: 1)")
        var nth: Int = 1

        @Flag(name: [.customShort("v"), .long], help: "Verbose output")
        var verbose: Bool = false

        @Option(name: [.customShort("d"), .long], help: "Maximum search depth (default: 10)")
        var depth: Int = 10

        @Flag(name: .shortAndLong, help: "Start search from focused window")
        var window: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            guard text != nil || role != nil || id != nil || subrole != nil else {
                print("Error: Specify search text, --role, --id, or --subrole")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            let rootElement: Accessibility.Element
            if window {
                guard let focusedWindow: Accessibility.Element = try? appElement.attribute(.init("AXFocusedWindow"))() else {
                    print("Error: Could not get focused window")
                    throw ExitCode.failure
                }
                rootElement = focusedWindow
            } else {
                rootElement = appElement
            }

            // Search for matching elements
            var matches: [(element: Accessibility.Element, path: String, info: String)] = []
            searchElements(root: rootElement, path: "", depth: 0, matches: &matches)

            if matches.isEmpty {
                print("No matching elements found")
                throw ExitCode.failure
            }

            if all {
                // Print all matches
                print("Found \(matches.count) match(es):\n")
                for (index, match) in matches.enumerated() {
                    print("[\(index + 1)] \(match.info)")
                    if verbose {
                        print("    path: \(match.path)")
                    }
                }
                return
            }

            // Select the Nth match
            guard nth >= 1 && nth <= matches.count else {
                print("Error: Match #\(nth) not found (only \(matches.count) match(es))")
                throw ExitCode.failure
            }

            let selected = matches[nth - 1]
            let element = selected.element

            print("Found: \(selected.info)")
            if verbose {
                print("  path: \(selected.path)")
                printElementDetails(element)
            }

            // Perform actions
            var actionPerformed = false

            if focus {
                let focusAttr = element.mutableAttribute(.init("AXFocused")) as Accessibility.MutableAttribute<Bool>
                if (try? focusAttr.isSettable()) == true {
                    try? focusAttr(assign: true)
                    print("→ Focused")
                    actionPerformed = true
                } else {
                    print("→ Cannot focus this element")
                }
            }

            if let typeValue = type {
                let valueAttr = element.mutableAttribute(.init("AXValue")) as Accessibility.MutableAttribute<String>
                if (try? valueAttr.isSettable()) == true {
                    try valueAttr(assign: typeValue)
                    print("→ Set value: \(typeValue)")
                    actionPerformed = true
                } else {
                    print("→ Cannot set value on this element")
                }
            }

            if click {
                let pressAction = element.action(.init("AXPress"))
                do {
                    try pressAction()
                    print("→ Clicked")
                    actionPerformed = true
                } catch {
                    // Try AXPick for menu items
                    let pickAction = element.action(.init("AXPick"))
                    do {
                        try pickAction()
                        print("→ Picked")
                        actionPerformed = true
                    } catch {
                        print("→ Cannot click this element (no AXPress or AXPick action)")
                    }
                }
            }

            if read {
                if let value: Any = try? element.attribute(.init("AXValue"))() {
                    print("→ Value: \(value)")
                } else if let title: String = try? element.attribute(AXAttribute.title)() {
                    print("→ Title: \(title)")
                } else {
                    print("→ No readable value")
                }
                actionPerformed = true
            }

            if let customActionName = custom {
                try performCustomAction(customActionName, on: element)
                actionPerformed = true
            }

            if !actionPerformed && matches.count > 1 {
                print("\n\(matches.count) total matches. Use --all to see all, or -n <num> to select.")
            }
        }

        private func performCustomAction(_ name: String, on element: Accessibility.Element) throws {
            guard let actions = try? element.supportedActions() else {
                print("→ Cannot read actions for element")
                throw ExitCode.failure
            }

            // Find custom action matching the name
            // Custom actions have format: "Name:...\nTarget:...\nSelector:..."
            var matchingAction: Accessibility.Action?
            for action in actions {
                let actionName = action.name.value
                if actionName.hasPrefix("Name:") {
                    let parsed = parseCustomAction(actionName)
                    if parsed.lowercased() == name.lowercased() {
                        matchingAction = action
                        break
                    }
                }
            }

            guard let action = matchingAction else {
                print("→ Custom action '\(name)' not found")
                print()
                print("Available custom actions:")
                for action in actions {
                    let actionName = action.name.value
                    if actionName.hasPrefix("Name:") {
                        let parsed = parseCustomAction(actionName)
                        print("  - \(parsed)")
                    }
                }
                throw ExitCode.failure
            }

            try action()
            print("→ Custom action: \(name)")
        }

        private func parseCustomAction(_ raw: String) -> String {
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let lineStr = String(line)
                if lineStr.hasPrefix("Name:") {
                    return String(lineStr.dropFirst(5))
                }
            }
            return raw
        }

        private func searchElements(
            root: Accessibility.Element,
            path: String,
            depth: Int,
            matches: inout [(element: Accessibility.Element, path: String, info: String)]
        ) {
            guard depth <= self.depth else { return }

            // Check if this element matches
            if elementMatches(root) {
                let info = formatElementInfo(root)
                matches.append((root, path.isEmpty ? "root" : path, info))
            }

            // Recurse into children
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = root.attribute(.init("AXChildren"))
            guard let children = try? childrenAttr() else { return }

            for (index, child) in children.enumerated() {
                let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
                searchElements(root: child, path: childPath, depth: depth + 1, matches: &matches)
            }
        }

        private func elementMatches(_ element: Accessibility.Element) -> Bool {
            // Check role filter
            if let roleFilter = role {
                guard let elementRole: String = try? element.attribute(AXAttribute.role)() else {
                    return false
                }
                let normalizedFilter = roleFilter.hasPrefix("AX") ? roleFilter : "AX\(roleFilter)"
                if elementRole.lowercased() != normalizedFilter.lowercased() {
                    return false
                }
            }

            // Check subrole filter
            if let subroleFilter = subrole {
                guard let elementSubrole: String = try? element.attribute(AXAttribute.subrole)() else {
                    return false
                }
                let normalizedFilter = subroleFilter.hasPrefix("AX") ? subroleFilter : "AX\(subroleFilter)"
                if elementSubrole.lowercased() != normalizedFilter.lowercased() {
                    return false
                }
            }

            // Check identifier filter
            if let idFilter = id {
                guard let elementId: String = try? element.attribute(AXAttribute.identifier)() else {
                    return false
                }
                if !elementId.localizedCaseInsensitiveContains(idFilter) {
                    return false
                }
            }

            // Check text filter (matches title, value, description, or identifier)
            if let textFilter = text {
                let searchText = textFilter.lowercased()

                let title = (try? element.attribute(AXAttribute.title)())?.lowercased() ?? ""
                let value = (try? element.attribute(AXAttribute.value)()).map { String(describing: $0).lowercased() } ?? ""
                let desc = (try? element.attribute(AXAttribute.description)())?.lowercased() ?? ""
                let identifier = (try? element.attribute(AXAttribute.identifier)())?.lowercased() ?? ""
                let help = (try? element.attribute(AXAttribute.help)())?.lowercased() ?? ""

                let matchesText = title.contains(searchText) ||
                                  value.contains(searchText) ||
                                  desc.contains(searchText) ||
                                  identifier.contains(searchText) ||
                                  help.contains(searchText)

                if !matchesText {
                    return false
                }
            }

            return true
        }

        private func formatElementInfo(_ element: Accessibility.Element) -> String {
            var parts: [String] = []

            if let role: String = try? element.attribute(AXAttribute.role)() {
                parts.append(role.replacingOccurrences(of: "AX", with: ""))
            }

            if let title: String = try? element.attribute(AXAttribute.title)(), !title.isEmpty {
                let truncated = title.count > 40 ? String(title.prefix(40)) + "..." : title
                parts.append("\"\(truncated)\"")
            }

            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                parts.append("#\(id)")
            }

            if let value: Any = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                if !strValue.isEmpty && strValue != parts.last {
                    let truncated = strValue.count > 30 ? String(strValue.prefix(30)) + "..." : strValue
                    parts.append("=\(truncated)")
                }
            }

            return parts.joined(separator: " ")
        }

        private func printElementDetails(_ element: Accessibility.Element) {
            if let enabled: Bool = try? element.attribute(AXAttribute.enabled)() {
                print("  enabled: \(enabled)")
            }
            if let focused: Bool = try? element.attribute(AXAttribute.focused)() {
                print("  focused: \(focused)")
            }
            if let frame = try? element.attribute(AXAttribute.frame)() {
                print("  frame: (\(Int(frame.origin.x)),\(Int(frame.origin.y))) \(Int(frame.width))x\(Int(frame.height))")
            }
            if let actions = try? element.supportedActions(), !actions.isEmpty {
                let names = actions.map { $0.name.value.replacingOccurrences(of: "AX", with: "") }
                print("  actions: \(names.joined(separator: ", "))")
            }
        }
    }
}
