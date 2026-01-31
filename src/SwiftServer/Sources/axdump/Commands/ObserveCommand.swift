import Foundation
import ArgumentParser
import AccessibilityControl

extension AXDump {
    struct Observe: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Observe accessibility notifications for an application",
            discussion: """
                Monitor accessibility notifications in real-time. Each notification is printed
                with a timestamp. Press Ctrl+C to stop observing.

                COMMON NOTIFICATIONS:
                  AXValueChanged              - Element value changed
                  AXFocusedUIElementChanged   - Focus moved to different element
                  AXFocusedWindowChanged      - Different window got focus
                  AXSelectedTextChanged       - Text selection changed
                  AXSelectedChildrenChanged   - Child selection changed
                  AXWindowCreated/Moved/Resized - Window events
                  AXMenuOpened/Closed         - Menu events
                  AXApplicationActivated      - App became frontmost

                Use -n list to see all common notifications.

                EXAMPLES:
                  axdump observe 710                          Observe focus changes (default)
                  axdump observe 710 -n list                  List available notifications
                  axdump observe 710 -n AXValueChanged        Observe value changes
                  axdump observe 710 -n ValueChanged,Focused  Multiple (AX prefix optional)
                  axdump observe 710 -n all                   Observe all notifications
                  axdump observe 710 -n all -v                Verbose (show element details)
                  axdump observe 710 -w -n AXWindowMoved      Observe from focused window
                  axdump observe 710 -n all -j                JSON output
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("n"), .long], help: "Notification(s) to observe (comma-separated). Use 'list' to show, 'all' for all.")
        var notifications: String = "AXFocusedUIElementChanged"

        @Option(name: [.customShort("p"), .long], help: "Path to element to observe (dot-separated child indices)")
        var path: String?

        @Flag(name: [.customShort("F"), .long], help: "Observe focused element")
        var focused: Bool = false

        @Flag(name: .shortAndLong, help: "Observe focused window")
        var window: Bool = false

        @Flag(name: [.customShort("j"), .long], help: "Output as JSON")
        var json: Bool = false

        @Flag(name: [.customShort("v"), .long], help: "Verbose output (show element details)")
        var verbose: Bool = false

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            // Handle 'list' option
            if notifications.lowercased() == "list" {
                print("Common Accessibility Notifications:")
                print(String(repeating: "-", count: 40))
                for notification in AXNotifications.all {
                    print("  \(notification)")
                }
                return
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

            // Navigate via path if specified
            if let pathString = path {
                targetElement = try navigateToPath(from: targetElement, path: pathString)
            }

            // Print element info
            printElementInfo(targetElement)

            // Determine which notifications to observe
            let notificationNames: [String]
            if notifications.lowercased() == "all" {
                notificationNames = AXNotifications.all
            } else {
                notificationNames = notifications.split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("AX") ? $0 : "AX\($0)" }
            }

            print("Observing notifications: \(notificationNames.joined(separator: ", "))")
            print("Press Ctrl+C to stop")
            print(String(repeating: "=", count: 60))
            print()

            // Create observer
            let observer = try Accessibility.Observer(pid: pid, on: .main)

            // Store tokens to keep observations alive
            var tokens: [Accessibility.Observer.Token] = []

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss.SSS"

            let useColor = !noColor

            for notificationName in notificationNames {
                do {
                    let token = try observer.observe(
                        .init(notificationName),
                        for: targetElement
                    ) { [self] info in
                        let timestamp = dateFormatter.string(from: Date())

                        if json {
                            var output: [String: Any] = [
                                "timestamp": timestamp,
                                "notification": notificationName
                            ]

                            if let element = info["AXUIElement"] as? Accessibility.Element {
                                let printer = ElementPrinter()
                                output["element"] = printer.formatElementForJSON(element)
                                let pathInfo = computeElementPath(element, appElement: appElement)
                                output["path"] = pathInfo.path
                                output["chain"] = pathInfo.chain
                            }

                            if let jsonData = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                print(jsonString)
                            }
                        } else {
                            let notifColor = colorForNotification(notificationName)

                            var line = Color.dim.wrap("[\(timestamp)]", enabled: useColor) + " "
                            line += notifColor.wrap(notificationName, enabled: useColor)

                            if let element = info["AXUIElement"] as? Accessibility.Element {
                                let pathInfo = computeElementPath(element, appElement: appElement)
                                line += " " + Color.dim.wrap("@", enabled: useColor) + " "
                                line += Color.blue.wrap(pathInfo.path, enabled: useColor)
                                if verbose {
                                    line += "\n    " + Color.dim.wrap("chain:", enabled: useColor) + " "
                                    line += Color.magenta.wrap(pathInfo.chain, enabled: useColor)
                                    line += "\n    " + Color.dim.wrap("element:", enabled: useColor) + " "
                                    line += formatElementColored(element, useColor: useColor)
                                }
                            } else {
                                line += " " + Color.dim.wrap("(no element)", enabled: useColor)
                            }

                            print(line)
                        }

                        fflush(stdout)
                    }
                    tokens.append(token)
                } catch {
                    if verbose {
                        print("Warning: Could not observe \(notificationName): \(error)")
                    }
                }
            }

            if tokens.isEmpty {
                print("Error: Could not register for any notifications")
                throw ExitCode.failure
            }

            print("Successfully registered for \(tokens.count) notification(s)")
            print()

            // Keep running
            RunLoop.main.run()
        }

        private func printElementInfo(_ element: Accessibility.Element) {
            print("Observing Element:")
            print(String(repeating: "-", count: 40))

            if let role: String = try? element.attribute(AXAttribute.role)() {
                print("Role: \(role)")
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                print("Title: \(title)")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                print("Identifier: \(id)")
            }

            print()
        }

        private func colorForNotification(_ name: String) -> Color {
            switch name {
            case "AXValueChanged", "AXSelectedTextChanged":
                return .green
            case "AXFocusedUIElementChanged", "AXFocusedWindowChanged":
                return .cyan
            case "AXLayoutChanged", "AXResized", "AXMoved":
                return .yellow
            case "AXWindowCreated", "AXWindowMoved", "AXWindowResized":
                return .blue
            case "AXApplicationActivated", "AXApplicationDeactivated":
                return .magenta
            case "AXMenuOpened", "AXMenuClosed", "AXMenuItemSelected":
                return .brightMagenta
            case "AXUIElementDestroyed":
                return .red
            case "AXCreated":
                return .brightGreen
            case "AXTitleChanged":
                return .brightCyan
            default:
                return .white
            }
        }

        private func formatElementColored(_ element: Accessibility.Element, useColor: Bool) -> String {
            var parts: [String] = []

            if let role: String = try? element.attribute(AXAttribute.role)() {
                parts.append(Color.cyan.wrap("role", enabled: useColor) + "=" + Color.white.wrap(role, enabled: useColor))
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                let truncated = title.count > 30 ? String(title.prefix(30)) + "..." : title
                parts.append(Color.yellow.wrap("title", enabled: useColor) + "=\"" + Color.white.wrap(truncated, enabled: useColor) + "\"")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                parts.append(Color.green.wrap("id", enabled: useColor) + "=\"" + Color.white.wrap(id, enabled: useColor) + "\"")
            }
            if let value: Any = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                let truncated = strValue.count > 30 ? String(strValue.prefix(30)) + "..." : strValue
                parts.append(Color.magenta.wrap("value", enabled: useColor) + "=\"" + Color.white.wrap(truncated, enabled: useColor) + "\"")
            }

            return parts.isEmpty ? "(element)" : parts.joined(separator: " ")
        }
    }
}
