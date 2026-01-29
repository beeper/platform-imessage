import Foundation
import ArgumentParser
import AccessibilityControl

extension AXDump {
    struct Set: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Set an attribute value on an accessibility element",
            discussion: """
                Set mutable attribute values on elements. Navigate to the target element
                using path notation or focus options.

                COMMON SETTABLE ATTRIBUTES:
                  AXValue     - Element's value (text fields, sliders, etc.)
                  AXFocused   - Whether element has focus (true/false)

                VALUE TYPES:
                  - Strings: Just provide the text
                  - Booleans: true, false, yes, no, 1, 0
                  - Numbers: Integer or decimal values

                EXAMPLES:
                  axdump set 710 -a Value -v "Hello" -p 0.1.2    Set text value
                  axdump set 710 -a Focused -v true -p 0.1       Focus element
                  axdump set 710 -a Value -v 50 -p 0.3           Set slider to 50
                  axdump set 710 -a Value -v "search term" -F    Set focused element's value
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("a"), .long], help: "Attribute to set (can omit 'AX' prefix)")
        var attribute: String

        @Option(name: [.customShort("v"), .long], help: "Value to set")
        var value: String

        @Option(name: [.customShort("p"), .long], help: "Path to element (dot-separated child indices)")
        var path: String?

        @Option(name: [.customShort("c"), .long], help: "Index of child element")
        var child: Int?

        @Flag(name: [.customShort("F"), .long], help: "Target the focused element")
        var focused: Bool = false

        @Flag(name: .shortAndLong, help: "Target the focused window")
        var window: Bool = false

        @Flag(name: .long, help: "Verbose output")
        var verbose: Bool = false

        func run() throws {
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

            if let childIndex = child {
                targetElement = try navigateToChild(from: targetElement, index: childIndex)
            }

            if let pathString = path {
                targetElement = try navigateToPath(from: targetElement, path: pathString)
            }

            // Normalize attribute name
            let attrName = attribute.hasPrefix("AX") ? attribute : "AX\(attribute)"

            // Print element info if verbose
            if verbose {
                printElementInfo(targetElement)
            }

            // Check if attribute is settable
            let attr = targetElement.attribute(.init(attrName)) as Accessibility.Attribute<Any>
            guard (try? attr.isSettable()) == true else {
                print("Error: Attribute '\(attrName)' is not settable on this element")
                throw ExitCode.failure
            }

            // Get current value for comparison
            let oldValue: Any? = try? attr()

            // Parse and set the value based on attribute type
            do {
                try setValue(value, forAttribute: attrName, on: targetElement)

                print("Set \(attrName) = \(value)")

                if verbose {
                    if let old = oldValue {
                        print("  Previous value: \(String(describing: old))")
                    }
                    // Read back the new value
                    if let newValue: Any = try? attr() {
                        print("  New value: \(String(describing: newValue))")
                    }
                }
            } catch {
                print("Error: Failed to set \(attrName): \(error)")
                throw ExitCode.failure
            }
        }

        private func setValue(_ valueStr: String, forAttribute attrName: String, on element: Accessibility.Element) throws {
            // Try to determine the appropriate type based on the attribute name and value
            switch attrName {
            case "AXFocused", "AXEnabled", "AXSelected", "AXDisclosed", "AXExpanded":
                // Boolean attributes
                let boolValue = parseBool(valueStr)
                let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<Bool>
                try mutableAttr(assign: boolValue)

            case "AXValue":
                // Value can be string, number, or bool depending on element
                // Try number first, then bool, then string
                if let intVal = Int(valueStr) {
                    let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<Int>
                    try mutableAttr(assign: intVal)
                } else if let doubleVal = Double(valueStr) {
                    let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<Double>
                    try mutableAttr(assign: doubleVal)
                } else if valueStr.lowercased() == "true" || valueStr.lowercased() == "false" {
                    let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<Bool>
                    try mutableAttr(assign: parseBool(valueStr))
                } else {
                    // Default to string
                    let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<String>
                    try mutableAttr(assign: valueStr)
                }

            default:
                // Default: try as string
                let mutableAttr = element.mutableAttribute(.init(attrName)) as Accessibility.MutableAttribute<String>
                try mutableAttr(assign: valueStr)
            }
        }

        private func parseBool(_ value: String) -> Bool {
            switch value.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return !value.isEmpty
            }
        }

        private func printElementInfo(_ element: Accessibility.Element) {
            print("Target Element:")
            print(String(repeating: "-", count: 40))

            if let role: String = try? element.attribute(AXAttribute.role)() {
                print("  Role: \(role)")
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                print("  Title: \(title)")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                print("  Identifier: \(id)")
            }

            print()
        }
    }
}
