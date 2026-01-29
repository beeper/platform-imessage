import Foundation
import ArgumentParser
import AccessibilityControl

extension AXDump {
    struct Action: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Perform an action on an accessibility element",
            discussion: """
                Execute accessibility actions on elements. Navigate to the target element
                using path notation or focus options.

                \(AXActions.helpText())

                CUSTOM ACTIONS:
                  Some elements expose custom actions (e.g., tapback reactions in Messages).
                  Use --custom (-C) to perform these by name. Use --list to see available
                  custom actions for an element.

                EXAMPLES:
                  axdump action 710 -a Press -p 0.1.2        Press element at path
                  axdump action 710 -a Press -F              Press focused element
                  axdump action 710 -a Raise -w              Raise focused window
                  axdump action 710 -a Increment -p 0.3      Increment slider
                  axdump action 710 -a ShowMenu -F           Show context menu
                  axdump action 710 --list -p 0.1            List actions for element
                  axdump action 710 --list-actions           Show all known actions
                  axdump action 710 -C "Heart" -p 0.0.0.0.0.0.11.0   Perform custom action
                  axdump action 710 -C "Thumbs up" -p 0.1.2  Perform tapback reaction
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("a"), .long], help: "Standard AX action to perform (can omit 'AX' prefix)")
        var action: String?

        @Option(name: [.customShort("C"), .long], help: "Custom action to perform by name (e.g., 'Heart', 'Thumbs up')")
        var custom: String?

        @Option(name: [.customShort("p"), .long], help: "Path to element (dot-separated child indices)")
        var path: String?

        @Option(name: [.customShort("c"), .long], help: "Index of child element (shorthand for single-level path)")
        var child: Int?

        @Flag(name: [.customShort("F"), .long], help: "Target the focused element")
        var focused: Bool = false

        @Flag(name: .shortAndLong, help: "Target the focused window")
        var window: Bool = false

        @Flag(name: .long, help: "List available actions for the target element")
        var list: Bool = false

        @Flag(name: .long, help: "List all known accessibility actions")
        var listActions: Bool = false

        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose: Bool = false

        func run() throws {
            // Handle global list
            if listActions {
                print(AXActions.fullHelpText())
                return
            }

            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            // Determine target element
            var targetElement: Accessibility.Element = appElement

            if focused {
                guard let focusedElement: Accessibility.Element = try? appElement.attribute(.init("AXFocusedUIElement"))() else {
                    print("Error: Could not get focused element for PID \(pid)")
                    throw ExitCode.failure
                }
                targetElement = focusedElement
            } else if window {
                guard let focusedWindow: Accessibility.Element = try? appElement.attribute(.init("AXFocusedWindow"))() else {
                    print("Error: Could not get focused window for PID \(pid)")
                    throw ExitCode.failure
                }
                targetElement = focusedWindow
            }

            // Navigate to child if specified
            if let childIndex = child {
                targetElement = try navigateToChild(from: targetElement, index: childIndex)
            }

            // Navigate via path if specified
            if let pathString = path {
                targetElement = try navigateToPath(from: targetElement, path: pathString)
            }

            // Print element info
            if verbose {
                printElementInfo(targetElement)
            }

            // Handle list
            if list {
                listActionsForElement(targetElement)
                return
            }

            // Handle custom action
            if let customActionName = custom {
                try performCustomAction(customActionName, on: targetElement)
                return
            }

            // Require action
            guard let actionName = action else {
                print("Error: No action specified. Use -a <action>, -C <custom>, or --list to see available actions.")
                throw ExitCode.failure
            }

            // Perform standard AX action
            let fullActionName = actionName.hasPrefix("AX") ? actionName : "AX\(actionName)"

            do {
                let axAction = targetElement.action(.init(fullActionName))
                try axAction()

                print("Action performed: \(fullActionName)")

                if verbose {
                    // Show element state after action
                    print()
                    print("Element state after action:")
                    printElementInfo(targetElement)
                }
            } catch {
                print("Error: Failed to perform action '\(fullActionName)': \(error)")
                throw ExitCode.failure
            }
        }

        private func performCustomAction(_ name: String, on element: Accessibility.Element) throws {
            // Get all actions and find matching custom action
            guard let actions = try? element.supportedActions() else {
                print("Error: Could not read actions for element")
                throw ExitCode.failure
            }

            // Find custom action matching the name
            // Custom actions have format: "Name:...\nTarget:...\nSelector:..."
            var matchingAction: Accessibility.Action?
            for action in actions {
                let actionName = action.name.value
                if actionName.hasPrefix("Name:") {
                    // Parse custom action name
                    let parsed = parseCustomAction(actionName)
                    if parsed.name.lowercased() == name.lowercased() {
                        matchingAction = action
                        break
                    }
                }
            }

            guard let action = matchingAction else {
                print("Error: Custom action '\(name)' not found")
                print()
                print("Available custom actions:")
                for action in actions {
                    let actionName = action.name.value
                    if actionName.hasPrefix("Name:") {
                        let parsed = parseCustomAction(actionName)
                        print("  - \(parsed.name)")
                    }
                }
                throw ExitCode.failure
            }

            // Perform the action
            do {
                try action()
                print("Custom action performed: \(name)")

                if verbose {
                    print()
                    print("Element state after action:")
                    printElementInfo(element)
                }
            } catch {
                print("Error: Failed to perform custom action '\(name)': \(error)")
                throw ExitCode.failure
            }
        }

        private func parseCustomAction(_ raw: String) -> (name: String, target: String?, selector: String?) {
            var name = ""
            var target: String?
            var selector: String?

            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let lineStr = String(line)
                if lineStr.hasPrefix("Name:") {
                    name = String(lineStr.dropFirst(5))
                } else if lineStr.hasPrefix("Target:") {
                    target = String(lineStr.dropFirst(7))
                } else if lineStr.hasPrefix("Selector:") {
                    selector = String(lineStr.dropFirst(9))
                }
            }

            return (name, target, selector)
        }

        private func printElementInfo(_ element: Accessibility.Element) {
            print("Target Element:")
            print(String(repeating: "-", count: 40))

            if let role: String = try? element.attribute(AXAttribute.role)() {
                print("  Role: \(role)")
            }
            if let subrole: String = try? element.attribute(AXAttribute.subrole)() {
                print("  Subrole: \(subrole)")
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                print("  Title: \(title)")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                print("  Identifier: \(id)")
            }
            if let value: Any = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                let truncated = strValue.count > 50 ? String(strValue.prefix(50)) + "..." : strValue
                print("  Value: \(truncated)")
            }
            if let enabled: Bool = try? element.attribute(AXAttribute.enabled)() {
                print("  Enabled: \(enabled)")
            }
            if let focused: Bool = try? element.attribute(AXAttribute.focused)() {
                print("  Focused: \(focused)")
            }

            print()
        }

        private func listActionsForElement(_ element: Accessibility.Element) {
            guard let actions = try? element.supportedActions() else {
                print("(unable to read actions)")
                return
            }

            if actions.isEmpty {
                print("(no actions available)")
                return
            }

            // Separate standard and custom actions
            var standardActions: [Accessibility.Action] = []
            var customActions: [(name: String, action: Accessibility.Action)] = []

            for action in actions {
                let name = action.name.value
                if name.hasPrefix("Name:") {
                    let parsed = parseCustomAction(name)
                    customActions.append((parsed.name, action))
                } else {
                    standardActions.append(action)
                }
            }

            // Print standard actions
            if !standardActions.isEmpty {
                print("Standard Actions:")
                print(String(repeating: "-", count: 40))
                for action in standardActions.sorted(by: { $0.name.value < $1.name.value }) {
                    let name = action.name.value
                    let shortName = name.replacingOccurrences(of: "AX", with: "")
                    let knownDesc = AXActions.all[name]
                    let desc = knownDesc ?? action.description
                    print("  \(shortName.padding(toLength: 20, withPad: " ", startingAt: 0)) \(desc)")
                }
            }

            // Print custom actions
            if !customActions.isEmpty {
                if !standardActions.isEmpty { print() }
                print("Custom Actions (use -C \"name\"):")
                print(String(repeating: "-", count: 40))
                for (name, _) in customActions.sorted(by: { $0.name < $1.name }) {
                    print("  \(name)")
                }
            }
        }
    }
}
