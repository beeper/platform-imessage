import Foundation
import ArgumentParser
import AccessibilityControl
import CoreGraphics

extension AXDump {
    struct Inspect: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Inspect specific attributes or elements in full detail",
            discussion: """
                Read attribute values in full (without truncation) and navigate to specific
                elements in the hierarchy using child indices.

                NAVIGATION:
                  Use -c (--child) for single-level navigation or -p (--path) for multi-level.
                  Path format: dot-separated indices, e.g., "0.3.1" means:
                    - First child of root (index 0)
                    - Fourth child of that (index 3)
                    - Second child of that (index 1)

                ATTRIBUTES:
                  Use -a to specify attributes to read. Can omit 'AX' prefix.
                  Use -a list to see all available attributes for an element.

                EXAMPLES:
                  axdump inspect 710                     Show all attributes (full values)
                  axdump inspect 710 -a list             List available attributes
                  axdump inspect 710 -a AXValue          Read AXValue in full
                  axdump inspect 710 -a Value,Title      Read multiple (AX prefix optional)
                  axdump inspect 710 -c 0                Inspect first child
                  axdump inspect 710 -p 0.2.1            Navigate to nested element
                  axdump inspect 710 -w -a AXChildren    From focused window
                  axdump inspect 710 -F -p 0             First child of focused element
                  axdump inspect 710 -j                  Output as JSON
                  axdump inspect 710 -l 500              Truncate values at 500 chars
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("p"), .long], help: "Path to element as dot-separated child indices (e.g., '0.3.1')")
        var path: String?

        @Option(name: [.customShort("a"), .long], help: "Specific attribute(s) to read in full (comma-separated). Use 'list' to show available.")
        var attributes: String?

        @Option(name: [.customShort("c"), .long], help: "Index of child element to inspect (shorthand for --path)")
        var child: Int?

        @Flag(name: [.customShort("F"), .long], help: "Start from focused element")
        var focused: Bool = false

        @Flag(name: .shortAndLong, help: "Start from focused window")
        var window: Bool = false

        @Option(name: [.customShort("l"), .long], help: "Maximum output length per attribute (0 for unlimited)")
        var maxLength: Int = 0

        @Flag(name: [.customShort("j"), .long], help: "Output as JSON")
        var json: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            // Determine starting element
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

            // Show element info
            printElementHeader(targetElement)

            let printer = ElementPrinter(maxLength: maxLength)

            // Handle attribute inspection
            if let attrString = attributes {
                if attrString.lowercased() == "list" {
                    listAttributes(of: targetElement)
                } else {
                    let attrNames = attrString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    inspectAttributes(of: targetElement, names: attrNames, printer: printer)
                }
            } else {
                // Default: show all attributes with full values
                inspectAllAttributes(of: targetElement, printer: printer)
            }
        }

        private func printElementHeader(_ element: Accessibility.Element) {
            print("Element Info:")
            print(String(repeating: "=", count: 60))

            if let role: String = try? element.attribute(AXAttribute.role)() {
                print("Role: \(role)")
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                print("Title: \(title)")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                print("Identifier: \(id)")
            }

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            if let count = try? childrenAttr.count() {
                print("Children: \(count)")
            }

            print(String(repeating: "-", count: 60))
            print()
        }

        private func listAttributes(of element: Accessibility.Element) {
            print("Available Attributes:")
            print(String(repeating: "-", count: 40))

            guard let attributes = try? element.supportedAttributes() else {
                print("(unable to read attributes)")
                return
            }

            for attr in attributes.sorted(by: { $0.name.value < $1.name.value }) {
                let name = attr.name.value
                let settable = (try? attr.isSettable()) ?? false
                let settableStr = settable ? " [settable]" : ""
                print("  \(name)\(settableStr)")
            }

            print()
            print("Parameterized Attributes:")
            print(String(repeating: "-", count: 40))

            if let paramAttrs = try? element.supportedParameterizedAttributes() {
                for attr in paramAttrs.sorted(by: { $0.name.value < $1.name.value }) {
                    print("  \(attr.name.value)")
                }
            }
        }

        private func inspectAttributes(of element: Accessibility.Element, names: [String], printer: ElementPrinter) {
            if json {
                var result: [String: Any] = [:]
                for name in names {
                    let attrName = name.hasPrefix("AX") ? name : "AX\(name)"
                    if let value: Any = try? element.attribute(.init(attrName))() {
                        result[attrName] = printer.formatValueForJSON(value)
                    } else {
                        result[attrName] = NSNull()
                    }
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
                return
            }

            for name in names {
                let attrName = name.hasPrefix("AX") ? name : "AX\(name)"
                print("\(attrName):")
                print(String(repeating: "-", count: 40))

                if let value: Any = try? element.attribute(.init(attrName))() {
                    let strValue = printer.formatValue(value)
                    if maxLength > 0 && strValue.count > maxLength {
                        print(String(strValue.prefix(maxLength)))
                        print("... (truncated, total length: \(strValue.count))")
                    } else {
                        print(strValue)
                    }
                } else {
                    print("(unable to read or no value)")
                }
                print()
            }
        }

        private func inspectAllAttributes(of element: Accessibility.Element, printer: ElementPrinter) {
            guard let attributes = try? element.supportedAttributes() else {
                print("(unable to read attributes)")
                return
            }

            if json {
                var result: [String: Any] = [:]
                for attr in attributes {
                    if let value: Any = try? attr() {
                        result[attr.name.value] = printer.formatValueForJSON(value)
                    }
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
                return
            }

            print("All Attributes (full values):")
            print(String(repeating: "-", count: 40))

            for attr in attributes.sorted(by: { $0.name.value < $1.name.value }) {
                let name = attr.name.value

                if let value: Any = try? attr() {
                    let strValue = printer.formatValue(value)
                    if maxLength > 0 && strValue.count > maxLength {
                        print("\(name): \(String(strValue.prefix(maxLength)))... (truncated)")
                    } else if strValue.contains("\n") || strValue.count > 80 {
                        print("\(name):")
                        print(strValue.split(separator: "\n", omittingEmptySubsequences: false)
                            .map { "  \($0)" }
                            .joined(separator: "\n"))
                    } else {
                        print("\(name): \(strValue)")
                    }
                } else {
                    print("\(name): (unable to read)")
                }
            }
        }
    }
}
