import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit

extension AXDump {
    struct Dump: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Dump accessibility tree for an application",
            discussion: """
                Recursively dumps the accessibility element hierarchy starting from the
                application root or focused window. Output is rendered as an ASCII tree.

                \(AttributeFields.helpText)

                \(ElementFilter.helpText)

                \(AXRoles.helpText())

                EXAMPLES:
                  axdump dump 710                        Dump with default settings
                  axdump dump 710 -d 5                   Dump 5 levels deep
                  axdump dump 710 -f minimal             Only show role, title, id
                  axdump dump 710 -f role,title,value    Custom field selection
                  axdump dump 710 -w                     Start from focused window
                  axdump dump 710 --role Button          Filter to only buttons
                  axdump dump 710 --has identifier       Only elements with identifier
                  axdump dump 710 --role "Text.*" -d 10  Regex pattern for roles
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: .shortAndLong, help: "Maximum depth to traverse (default: 3)")
        var depth: Int = 3

        @Option(name: .shortAndLong, help: "Verbosity level: 0=minimal, 1=normal, 2=detailed")
        var verbosity: Int = 1

        @Option(name: [.customShort("f"), .long], help: "Fields to display (see FIELD OPTIONS above)")
        var fields: String = "standard"

        @Flag(name: .shortAndLong, help: "Start from focused window instead of application root")
        var window: Bool = false

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        // Filtering options
        @Option(name: .long, help: "Filter by role (regex pattern, e.g., 'Button|Text')")
        var role: String?

        @Option(name: .long, help: "Filter by subrole (regex pattern)")
        var subrole: String?

        @Option(name: .long, help: "Filter by title (regex pattern)")
        var title: String?

        @Option(name: .long, help: "Filter by identifier (regex pattern)")
        var id: String?

        @Option(name: .long, parsing: .upToNextOption, help: "Only show elements where these fields are not nil")
        var has: [String] = []

        @Option(name: .long, parsing: .upToNextOption, help: "Only show elements where these fields are nil")
        var without: [String] = []

        @Flag(name: .long, help: "Make pattern matching case-sensitive")
        var caseSensitive: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            let rootElement: Accessibility.Element
            if window {
                guard let focusedWindow: Accessibility.Element = try? appElement.attribute(.init("AXFocusedWindow"))() else {
                    print("Error: Could not get focused window for PID \(pid)")
                    throw ExitCode.failure
                }
                rootElement = focusedWindow
            } else {
                rootElement = appElement
            }

            // Build filter
            let filter: ElementFilter?
            do {
                filter = try ElementFilter(
                    rolePattern: role,
                    subrolePattern: subrole,
                    titlePattern: title,
                    identifierPattern: id,
                    requiredFields: has,
                    excludedFields: without,
                    caseSensitive: caseSensitive
                )
            } catch {
                print("Error: Invalid regex pattern: \(error)")
                throw ExitCode.failure
            }

            let attributeFields = AttributeFields.parse(fields)

            // Print header
            if let appName: String = try? appElement.attribute(.init("AXTitle"))() {
                print("Accessibility Tree for: \(appName) (PID: \(pid))")
            } else {
                print("Accessibility Tree for PID: \(pid)")
            }
            print(String(repeating: "=", count: 60))

            if let f = filter, f.isActive {
                print("Filters active: \(describeFilter(f))")
                print(String(repeating: "-", count: 60))
            }
            print()

            if json {
                let jsonTree = buildJSONTree(rootElement, depth: depth, filter: filter)
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonTree, options: [.prettyPrinted, .sortedKeys]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
            } else {
                let printer = TreePrinter(
                    fields: attributeFields,
                    filter: filter?.isActive == true ? filter : nil,
                    maxDepth: depth,
                    showActions: verbosity >= 2,
                    useColor: !noColor
                )
                printer.printTree(rootElement)
            }
        }

        private func describeFilter(_ filter: ElementFilter) -> String {
            var parts: [String] = []
            if filter.rolePattern != nil { parts.append("role") }
            if filter.subrolePattern != nil { parts.append("subrole") }
            if filter.titlePattern != nil { parts.append("title") }
            if filter.identifierPattern != nil { parts.append("id") }
            if !filter.requiredFields.isEmpty { parts.append("has:\(filter.requiredFields.joined(separator: ","))") }
            if !filter.excludedFields.isEmpty { parts.append("without:\(filter.excludedFields.joined(separator: ","))") }
            return parts.joined(separator: ", ")
        }

        private func buildJSONTree(_ element: Accessibility.Element, depth: Int, filter: ElementFilter?) -> [String: Any] {
            let printer = ElementPrinter()
            var node = printer.formatElementForJSON(element)

            if depth > 0 {
                let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
                if let children: [Accessibility.Element] = try? childrenAttr() {
                    var childNodes: [[String: Any]] = []
                    for child in children {
                        let passes = filter?.matches(child) ?? true
                        if passes || childHasMatchingDescendant(child, filter: filter, depth: depth - 1) {
                            childNodes.append(buildJSONTree(child, depth: depth - 1, filter: filter))
                        }
                    }
                    if !childNodes.isEmpty {
                        node["children"] = childNodes
                    }
                }
            }

            return node
        }

        private func childHasMatchingDescendant(_ element: Accessibility.Element, filter: ElementFilter?, depth: Int) -> Bool {
            guard let filter = filter, depth > 0 else { return false }
            if filter.matches(element) { return true }

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            guard let children: [Accessibility.Element] = try? childrenAttr() else { return false }

            for child in children {
                if childHasMatchingDescendant(child, filter: filter, depth: depth - 1) {
                    return true
                }
            }
            return false
        }
    }
}
