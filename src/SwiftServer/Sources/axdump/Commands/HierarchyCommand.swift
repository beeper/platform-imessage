import Foundation
import ArgumentParser
import AccessibilityControl
import BetterSwiftAXAdditions
import AppKit

// MARK: - Hierarchy Command

struct Hierarchy: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "hierarchy",
        abstract: "Fetch and display the complete accessibility hierarchy using private API",
        discussion: """
            Uses the private AXUIElementCopyHierarchy function to fetch the entire
            accessibility tree in a single call. This is much faster than recursive
            traversal, especially for apps with large accessibility trees (4000+ nodes).

            The API prefetches specified attributes for all elements in a single call.

            OPTIONS:
              --max-depth <n>       Limit traversal depth (uses private option key)
              --max-array-count <n> Limit children per element (uses private option key)

            EXAMPLES:
              axdump hierarchy 710                    Dump full hierarchy
              axdump hierarchy 710 -d 3              Limit display depth to 3 levels
              axdump hierarchy 710 --json            Output as JSON
              axdump hierarchy 710 --max-depth 5     Limit API traversal to 5 levels
              axdump hierarchy 710 --find SceneWindow  Find element by identifier
            """
    )

    @Argument(help: "Process ID of the application")
    var pid: pid_t

    @Option(name: .shortAndLong, help: "Maximum display depth (default: unlimited)")
    var depth: Int?

    @Option(name: .long, help: "Maximum traversal depth for API call (uses private option key)")
    var maxDepth: Int?

    @Option(name: .long, help: "Maximum array count (children per element) for API call")
    var maxArrayCount: Int?

    @Option(name: .long, help: "Find element with this identifier")
    var find: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Flag(name: .shortAndLong, help: "Start from the focused window instead of the app")
    var window: Bool = false

    @Flag(name: .long, help: "Disable colored output")
    var noColor: Bool = false

    @Flag(name: .long, help: "Show statistics only")
    var stats: Bool = false

    @Flag(name: .long, help: "Show detailed result info (incomplete status, errors)")
    var detailed: Bool = false

    func run() async throws {
        let app = Accessibility.Element(pid: pid)

        // Get the root element
        let root: Accessibility.Element
        if window {
            guard let focusedWindow: Accessibility.Element = try? app.attribute(.init("AXFocusedWindow"))() else {
                throw ValidationError("Could not get focused window for PID \(pid)")
            }
            root = focusedWindow
        } else {
            root = app
        }

        // Build options
        // Note: The private option keys (maxDepth, maxArrayCount) are loaded and passed correctly,
        // but their effect on the API behavior appears to be minimal or internal (e.g., caching).
        // The API still returns all elements regardless of these options.
        var options = CopyHierarchyOptions()
        if let maxDepth = maxDepth {
            options.maxDepth = maxDepth
        }
        if let maxArrayCount = maxArrayCount {
            options.maxArrayCount = maxArrayCount
        }

        print("Fetching hierarchy for PID \(pid) using AXUIElementCopyHierarchy...")
        if maxDepth != nil || maxArrayCount != nil {
            print("Options: maxDepth=\(maxDepth.map(String.init) ?? "nil"), maxArrayCount=\(maxArrayCount.map(String.init) ?? "nil")")
        }
        let startTime = Date()

        if detailed {
            // Use detailed API to get incomplete status and errors
            guard let result = root.copyHierarchyDetailed(options: options) else {
                print("Error: AXUIElementCopyHierarchy returned nil (API may not be available)")
                return
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("Fetched \(result.elements.count) elements in \(String(format: "%.2f", elapsed))ms")
            if result.isIncomplete {
                print("⚠️  Result is INCOMPLETE (hierarchy was truncated)")
            }
            if let errors = result.errors, !errors.isEmpty {
                print("⚠️  Errors: \(errors)")
            }
            print()

            displayElements(result.elements, rootElement: root.raw)
        } else {
            // Use simple API
            guard let elements = root.copyHierarchy(options: options) else {
                print("Error: AXUIElementCopyHierarchy returned nil (API may not be available)")
                return
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("Fetched \(elements.count) elements in \(String(format: "%.2f", elapsed))ms\n")

            displayElements(elements, rootElement: root.raw)
        }
    }

    private func displayElements(_ elements: [Accessibility.Element], rootElement: AXUIElement) {
        // Parse elements into nodes
        let parsed = elements.map { parseElement($0) }

        if stats {
            printStats(parsed)
            return
        }

        // Find specific element by identifier
        if let identifier = find {
            let matches = parsed.filter { $0.identifier == identifier }
            if matches.isEmpty {
                print("No elements found with identifier '\(identifier)'")
            } else {
                print("Found \(matches.count) element(s) with identifier '\(identifier)':\n")
                for (i, node) in matches.enumerated() {
                    print("[\(i + 1)] \(formatNode(node, useColor: !noColor))")
                    if let desc = node.description, !desc.isEmpty {
                        print("    desc: \"\(desc.prefix(80))\"")
                    }
                }
            }
            return
        }

        if json {
            // Output as JSON
            let jsonArray = parsed.map { node -> [String: Any] in
                var dict: [String: Any] = ["role": node.role]
                if let t = node.title { dict["title"] = t }
                if let id = node.identifier { dict["identifier"] = id }
                if let sr = node.subrole { dict["subrole"] = sr }
                if let d = node.description { dict["description"] = d }
                dict["childCount"] = node.childCount
                return dict
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        } else {
            // Build and print tree
            let tree = buildTree(from: parsed, rootElement: rootElement)
            if let rootNode = tree {
                printTree(rootNode, depth: 0, maxDepth: depth, useColor: !noColor)
            } else {
                print("Could not build tree (root element not found in hierarchy)")
                print("\nFlat list of elements:")
                for (i, node) in parsed.prefix(50).enumerated() {
                    print("[\(i)] \(formatNode(node, useColor: !noColor))")
                }
                if parsed.count > 50 {
                    print("... and \(parsed.count - 50) more elements")
                }
            }
        }
    }

    // MARK: - Parsed Node

    struct ParsedNode {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let title: String?
        let identifier: String?
        let description: String?
        let childElements: [AXUIElement]
        let childCount: Int
    }

    struct TreeNode {
        let node: ParsedNode
        var children: [TreeNode]
    }

    // MARK: - Parsing

    func parseElement(_ element: Accessibility.Element) -> ParsedNode {
        let role = (try? element.role()) ?? "?"
        let subrole = try? element.subrole()
        let title: String? = try? element.attribute(.init("AXTitle"))()
        let identifier: String? = try? element.attribute(.init("AXIdentifier"))()
        let description: String? = try? element.attribute(.init("AXDescription"))()
        let children: [Accessibility.Element] = (try? element.children()) ?? []

        return ParsedNode(
            element: element.raw,
            role: role,
            subrole: subrole,
            title: title,
            identifier: identifier,
            description: description,
            childElements: children.map(\.raw),
            childCount: children.count
        )
    }

    // MARK: - Tree Building

    func buildTree(from nodes: [ParsedNode], rootElement: AXUIElement) -> TreeNode? {
        // Find root node - try Application role first as it's always the root
        guard let rootNode = nodes.first(where: { $0.role == "AXApplication" }) else {
            return nil
        }

        // Create lookup by element for children
        var nodeMap: [AXUIElement: ParsedNode] = [:]
        for node in nodes {
            nodeMap[node.element] = node
        }

        // Track visited elements to prevent infinite recursion from cycles
        var visited = Set<ObjectIdentifier>()

        // Build tree recursively with cycle detection
        func buildNode(_ parsed: ParsedNode, depth: Int = 0) -> TreeNode? {
            // Prevent infinite recursion
            let id = ObjectIdentifier(parsed.element)
            guard !visited.contains(id), depth < 100 else {
                return nil
            }
            visited.insert(id)

            var treeNode = TreeNode(node: parsed, children: [])
            for childElement in parsed.childElements {
                if let childParsed = nodeMap[childElement],
                   let childTree = buildNode(childParsed, depth: depth + 1) {
                    treeNode.children.append(childTree)
                }
            }
            return treeNode
        }

        return buildNode(rootNode)
    }

    // MARK: - Formatting

    func formatNode(_ node: ParsedNode, useColor: Bool) -> String {
        var line = ""

        // Role (cyan)
        if useColor {
            line += "\u{001B}[36m\(node.role)\u{001B}[0m"
        } else {
            line += node.role
        }

        // Title (yellow, in quotes)
        if let t = node.title, !t.isEmpty {
            let truncated = t.count > 50 ? String(t.prefix(47)) + "..." : t
            if useColor {
                line += " \u{001B}[33m\"\(truncated)\"\u{001B}[0m"
            } else {
                line += " \"\(truncated)\""
            }
        }

        // Identifier (green, with #)
        if let id = node.identifier, !id.isEmpty {
            if useColor {
                line += " \u{001B}[32m#\(id)\u{001B}[0m"
            } else {
                line += " #\(id)"
            }
        }

        // Subrole (dim)
        if let sr = node.subrole, !sr.isEmpty, sr != node.role {
            let display = sr.hasPrefix("AX") ? String(sr.dropFirst(2)).lowercased() : sr
            if useColor {
                line += " \u{001B}[2m(\(display))\u{001B}[0m"
            } else {
                line += " (\(display))"
            }
        }

        return line
    }

    func printTree(_ treeNode: TreeNode, depth: Int, maxDepth: Int?, useColor: Bool) {
        if let max = maxDepth, depth > max {
            return
        }

        let indent = String(repeating: "│   ", count: max(0, depth - 1))
        let prefix = depth == 0 ? "" : "├── "

        print("\(indent)\(prefix)\(formatNode(treeNode.node, useColor: useColor))")

        for child in treeNode.children {
            printTree(child, depth: depth + 1, maxDepth: maxDepth, useColor: useColor)
        }
    }

    // MARK: - Stats

    func printStats(_ nodes: [ParsedNode]) {
        print("Total elements: \(nodes.count)")

        // Count by role
        var roleCounts: [String: Int] = [:]
        for node in nodes {
            roleCounts[node.role, default: 0] += 1
        }

        print("\nElements by role:")
        for (role, count) in roleCounts.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("  \(role): \(count)")
        }

        // Elements with identifiers
        let withIdentifiers = nodes.filter { $0.identifier != nil }
        print("\nElements with identifiers: \(withIdentifiers.count)")

        // List unique identifiers
        let identifiers = Set(withIdentifiers.compactMap { $0.identifier })
        if !identifiers.isEmpty {
            print("Unique identifiers:")
            for id in identifiers.sorted().prefix(20) {
                print("  #\(id)")
            }
            if identifiers.count > 20 {
                print("  ... and \(identifiers.count - 20) more")
            }
        }
    }
}
