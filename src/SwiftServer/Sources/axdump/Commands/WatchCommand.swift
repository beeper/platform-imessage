import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit
import CoreGraphics

extension AXDump {
    struct Watch: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Live watch element under mouse cursor",
            discussion: """
                Continuously displays information about the accessibility element under
                the mouse cursor. Useful for exploring UI and finding elements.

                Press Ctrl+C to stop.

                EXAMPLES:
                  axdump watch                    Watch any app
                  axdump watch 710                Watch only Finder (PID 710)
                  axdump watch --click            Also show click path
                  axdump watch --actions          Show available actions
                  axdump watch --path             Show element path for automation
                """
        )

        @Argument(help: "Optional: Only watch elements in this PID")
        var pid: Int32?

        @Flag(name: .long, help: "Show available actions on the element")
        var actions: Bool = false

        @Flag(name: .long, help: "Show element path (for use with other commands)")
        var path: Bool = false

        @Flag(name: .long, help: "Show full attribute list")
        var full: Bool = false

        @Option(name: [.customShort("i"), .long], help: "Update interval in milliseconds (default: 100)")
        var interval: Int = 100

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let useColor = !noColor
            print(Color.cyan.wrap("Watching accessibility elements under cursor...", enabled: useColor))
            print(Color.dim.wrap("Press Ctrl+C to stop\n", enabled: useColor))

            var lastElement: Accessibility.Element?
            var lastInfo = ""

            // Set up signal handler for clean exit
            signal(SIGINT) { _ in
                print("\n\nStopped watching.")
                Darwin.exit(0)
            }

            while true {
                let mouseLocation = NSEvent.mouseLocation

                // Convert to screen coordinates (flip Y)
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let point = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

                // Hit test to find element at point
                let systemWide = Accessibility.Element.systemWide
                guard let element: Accessibility.Element = try? systemWide.hitTest(x: Float(point.x), y: Float(point.y)) else {
                    Thread.sleep(forTimeInterval: Double(interval) / 1000.0)
                    continue
                }

                // If filtering by PID, check it
                if let filterPid = pid {
                    guard let elementPid = try? element.pid(), elementPid == filterPid else {
                        Thread.sleep(forTimeInterval: Double(interval) / 1000.0)
                        continue
                    }
                }

                // Check if element changed
                let currentInfo = formatElementInfo(element, useColor: useColor)
                if currentInfo != lastInfo || element != lastElement {
                    lastElement = element
                    lastInfo = currentInfo

                    // Clear previous output and print new info
                    print("\u{001B}[2J\u{001B}[H", terminator: "") // Clear screen
                    print(Color.cyan.wrap("═══ Element Under Cursor ═══", enabled: useColor))
                    print()
                    print(currentInfo)

                    if path {
                        printElementPath(element, useColor: useColor)
                    }

                    if actions {
                        printActions(element, useColor: useColor)
                    }

                    if full {
                        printFullAttributes(element, useColor: useColor)
                    }

                    print()
                    print(Color.dim.wrap("Mouse: (\(Int(point.x)), \(Int(point.y)))", enabled: useColor))
                    print(Color.dim.wrap("Press Ctrl+C to stop", enabled: useColor))
                }

                Thread.sleep(forTimeInterval: Double(interval) / 1000.0)
            }
        }

        private func formatElementInfo(_ element: Accessibility.Element, useColor: Bool) -> String {
            var lines: [String] = []

            // App info
            if let elementPid = try? element.pid() {
                let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier == elementPid }
                if let app = apps.first {
                    let appName = app.localizedName ?? "Unknown"
                    lines.append(Color.yellow.wrap("App:", enabled: useColor) + " \(appName) (PID: \(elementPid))")
                }
            }

            // Role
            if let role: String = try? element.attribute(AXAttribute.role)() {
                let shortRole = role.replacingOccurrences(of: "AX", with: "")
                var roleLine = Color.green.wrap("Role:", enabled: useColor) + " \(shortRole)"

                if let subrole: String = try? element.attribute(AXAttribute.subrole)() {
                    let shortSubrole = subrole.replacingOccurrences(of: "AX", with: "")
                    roleLine += " [\(shortSubrole)]"
                }
                lines.append(roleLine)
            }

            // Title
            if let title: String = try? element.attribute(AXAttribute.title)(), !title.isEmpty {
                lines.append(Color.green.wrap("Title:", enabled: useColor) + " \"\(title)\"")
            }

            // Identifier
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                lines.append(Color.green.wrap("ID:", enabled: useColor) + " \(id)")
            }

            // Value
            if let value: Any = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                let truncated = strValue.count > 50 ? String(strValue.prefix(50)) + "..." : strValue
                lines.append(Color.green.wrap("Value:", enabled: useColor) + " \(truncated)")
            }

            // Description
            if let desc: String = try? element.attribute(AXAttribute.description)(), !desc.isEmpty {
                lines.append(Color.green.wrap("Desc:", enabled: useColor) + " \"\(desc)\"")
            }

            // Enabled/Focused
            let enabled = (try? element.attribute(AXAttribute.enabled)()) ?? true
            let focused = (try? element.attribute(AXAttribute.focused)()) ?? false
            var stateLine = Color.green.wrap("State:", enabled: useColor)
            stateLine += enabled ? " enabled" : Color.red.wrap(" disabled", enabled: useColor)
            if focused {
                stateLine += Color.brightGreen.wrap(" [focused]", enabled: useColor)
            }
            lines.append(stateLine)

            // Frame
            if let frame = try? element.attribute(AXAttribute.frame)() {
                lines.append(Color.green.wrap("Frame:", enabled: useColor) +
                    " (\(Int(frame.origin.x)), \(Int(frame.origin.y))) \(Int(frame.width))×\(Int(frame.height))")
            }

            return lines.joined(separator: "\n")
        }

        private func printElementPath(_ element: Accessibility.Element, useColor: Bool) {
            print()
            print(Color.cyan.wrap("─── Path ───", enabled: useColor))

            // Try to compute path
            guard let elementPid = try? element.pid() else { return }
            let appElement = Accessibility.Element(pid: elementPid)

            var ancestors: [(element: Accessibility.Element, index: Int)] = []
            var current = element

            // Walk up to root
            while let parent: Accessibility.Element = try? current.attribute(.init("AXParent"))() {
                // Find index of current in parent's children
                let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = parent.attribute(.init("AXChildren"))
                var index = -1
                if let children = try? childrenAttr() {
                    index = children.firstIndex(of: current) ?? -1
                }
                ancestors.append((current, index))

                if parent == appElement {
                    break
                }
                current = parent
            }

            ancestors.reverse()

            // Build path string
            let pathIndices = ancestors.map { $0.index >= 0 ? String($0.index) : "?" }.joined(separator: ".")
            print(Color.yellow.wrap("Path:", enabled: useColor) + " \(pathIndices)")

            // Build chain description
            var chain: [String] = []
            for (elem, _) in ancestors {
                var desc = ""
                if let role: String = try? elem.attribute(AXAttribute.role)() {
                    desc = role.replacingOccurrences(of: "AX", with: "")
                }
                if let title: String = try? elem.attribute(AXAttribute.title)(), !title.isEmpty {
                    let short = title.count > 15 ? String(title.prefix(15)) + "..." : title
                    desc += "[\"\(short)\"]"
                } else if let id: String = try? elem.attribute(AXAttribute.identifier)() {
                    desc += "[#\(id)]"
                }
                chain.append(desc)
            }
            print(Color.dim.wrap("Chain:", enabled: useColor) + " " + chain.joined(separator: " > "))

            // Print command hint
            print()
            print(Color.dim.wrap("Use with:", enabled: useColor))
            print("  axdump inspect \(elementPid) -p \(pathIndices)")
            print("  axdump action \(elementPid) -a Press -p \(pathIndices)")
        }

        private func printActions(_ element: Accessibility.Element, useColor: Bool) {
            print()
            print(Color.cyan.wrap("─── Actions ───", enabled: useColor))

            guard let actions = try? element.supportedActions() else {
                print(Color.dim.wrap("(none)", enabled: useColor))
                return
            }

            if actions.isEmpty {
                print(Color.dim.wrap("(none)", enabled: useColor))
                return
            }

            for action in actions {
                let name = action.name.value.replacingOccurrences(of: "AX", with: "")
                let desc = AXActions.all[action.name.value] ?? action.description
                print("  \(Color.yellow.wrap(name, enabled: useColor)): \(desc)")
            }
        }

        private func printFullAttributes(_ element: Accessibility.Element, useColor: Bool) {
            print()
            print(Color.cyan.wrap("─── All Attributes ───", enabled: useColor))

            guard let attrs = try? element.supportedAttributes() else {
                print(Color.dim.wrap("(unable to read)", enabled: useColor))
                return
            }

            for attr in attrs.sorted(by: { $0.name.value < $1.name.value }) {
                let name = attr.name.value
                if let value: Any = try? attr() {
                    let strValue = String(describing: value)
                    let truncated = strValue.count > 40 ? String(strValue.prefix(40)) + "..." : strValue
                    print("  \(name): \(truncated)")
                }
            }
        }
    }
}
