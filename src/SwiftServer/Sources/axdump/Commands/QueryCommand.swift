import Foundation
import ArgumentParser
import AccessibilityControl

extension AXDump {
    struct Query: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Query specific element relationships",
            discussion: """
                Query relationships between accessibility elements like parent, children,
                siblings, or list all attributes of an element.

                RELATIONS:
                  children        - Direct child elements
                  parent          - Parent element
                  siblings        - Sibling elements (same parent)
                  windows         - Application windows
                  focused         - Focused window and UI element
                  all-attributes  - All attributes with truncated values (aliases: attrs, attributes)

                EXAMPLES:
                  axdump query 710 -r windows          List all windows
                  axdump query 710 -r children         Show app's direct children
                  axdump query 710 -r children -F      Children of focused element
                  axdump query 710 -r siblings -F      Siblings of focused element
                  axdump query 710 -r all-attributes   List all attributes (truncated)
                  axdump query 710 -r focused          Show focused window and element
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("r"), .long], help: "Relationship to query: children, parent, siblings, windows, focused, all-attributes")
        var relation: String = "children"

        @Option(name: [.customShort("f"), .long], help: "Fields to display")
        var fields: String = "standard"

        @Option(name: .shortAndLong, help: "Verbosity level")
        var verbosity: Int = 1

        @Flag(name: [.customShort("F"), .long], help: "Query from focused element instead of application root")
        var focused: Bool = false

        @Option(name: [.customShort("p"), .long], help: "Path to element (dot-separated child indices)")
        var path: String?

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            var targetElement: Accessibility.Element = appElement

            if focused {
                guard let focusedElement: Accessibility.Element = try? appElement.attribute(.init("AXFocusedUIElement"))() else {
                    print("Error: Could not get focused element for PID \(pid)")
                    throw ExitCode.failure
                }
                targetElement = focusedElement
            }

            if let pathString = path {
                targetElement = try navigateToPath(from: targetElement, path: pathString)
            }

            let attributeFields = AttributeFields.parse(fields)
            let printer = ElementPrinter(fields: attributeFields, verbosity: verbosity)

            switch relation.lowercased() {
            case "children":
                queryChildren(of: targetElement, printer: printer)

            case "parent":
                queryParent(of: targetElement, printer: printer)

            case "siblings":
                querySiblings(of: targetElement, printer: printer)

            case "windows":
                queryWindows(of: appElement, printer: printer)

            case "focused":
                queryFocused(of: appElement, printer: printer)

            case "all-attributes", "attrs", "attributes":
                queryAllAttributes(of: targetElement)

            default:
                print("Unknown relation: \(relation)")
                print("Valid options: children, parent, siblings, windows, focused, all-attributes")
                throw ExitCode.failure
            }
        }

        private func queryChildren(of element: Accessibility.Element, printer: ElementPrinter) {
            print("Children:")
            print(String(repeating: "-", count: 40))

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            guard let children: [Accessibility.Element] = try? childrenAttr() else {
                print("(no children or unable to read)")
                return
            }

            print("Count: \(children.count)")
            print()

            for (index, child) in children.enumerated() {
                print("[\(index)] \(printer.formatElement(child))")
            }
        }

        private func queryParent(of element: Accessibility.Element, printer: ElementPrinter) {
            print("Parent:")
            print(String(repeating: "-", count: 40))

            guard let parent: Accessibility.Element = try? element.attribute(.init("AXParent"))() else {
                print("(no parent or unable to read)")
                return
            }

            print(printer.formatElement(parent))
        }

        private func querySiblings(of element: Accessibility.Element, printer: ElementPrinter) {
            print("Siblings:")
            print(String(repeating: "-", count: 40))

            guard let parent: Accessibility.Element = try? element.attribute(.init("AXParent"))() else {
                print("(no parent - cannot determine siblings)")
                return
            }

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = parent.attribute(.init("AXChildren"))
            guard let siblings: [Accessibility.Element] = try? childrenAttr() else {
                print("(unable to read parent's children)")
                return
            }

            let filteredSiblings = siblings.filter { $0 != element }
            print("Count: \(filteredSiblings.count)")
            print()

            for (index, sibling) in filteredSiblings.enumerated() {
                print("[\(index)] \(printer.formatElement(sibling))")
            }
        }

        private func queryWindows(of element: Accessibility.Element, printer: ElementPrinter) {
            print("Windows:")
            print(String(repeating: "-", count: 40))

            let windowsAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXWindows"))
            guard let windows: [Accessibility.Element] = try? windowsAttr() else {
                print("(no windows or unable to read)")
                return
            }

            print("Count: \(windows.count)")
            print()

            for (index, window) in windows.enumerated() {
                print("[\(index)] \(printer.formatElement(window))")
            }
        }

        private func queryFocused(of element: Accessibility.Element, printer: ElementPrinter) {
            print("Focused Elements:")
            print(String(repeating: "-", count: 40))

            if let focusedWindow: Accessibility.Element = try? element.attribute(.init("AXFocusedWindow"))() {
                print("Focused Window:")
                print("  \(printer.formatElement(focusedWindow))")
                print()
            }

            if let focusedElement: Accessibility.Element = try? element.attribute(.init("AXFocusedUIElement"))() {
                print("Focused UI Element:")
                print("  \(printer.formatElement(focusedElement))")
            }
        }

        private func queryAllAttributes(of element: Accessibility.Element) {
            print("All Attributes:")
            print(String(repeating: "-", count: 40))

            guard let attributes = try? element.supportedAttributes() else {
                print("(unable to read attributes)")
                return
            }

            for attr in attributes.sorted(by: { $0.name.value < $1.name.value }) {
                let name = attr.name.value
                if let value: Any = try? attr() {
                    let strValue = String(describing: value)
                    let truncated = strValue.count > 80 ? String(strValue.prefix(80)) + "..." : strValue
                    print("\(name): \(truncated)")
                } else {
                    print("\(name): (unable to read)")
                }
            }

            print()
            print("Parameterized Attributes:")
            print(String(repeating: "-", count: 40))

            if let paramAttrs = try? element.supportedParameterizedAttributes() {
                for attr in paramAttrs.sorted(by: { $0.name.value < $1.name.value }) {
                    print(attr.name.value)
                }
            }

            print()
            print("Actions:")
            print(String(repeating: "-", count: 40))

            if let actions = try? element.supportedActions() {
                for action in actions.sorted(by: { $0.name.value < $1.name.value }) {
                    print("\(action.name.value): \(action.description)")
                }
            }
        }
    }
}
