import Foundation
import AccessibilityControl

// MARK: - ASCII Tree Printer

/// Prints accessibility elements in an ASCII tree format
struct TreePrinter {
    let fields: AttributeFields
    let filter: ElementFilter?
    let maxDepth: Int
    let showActions: Bool
    let useColor: Bool

    // Tree drawing characters
    private let branch = "├── "
    private let lastBranch = "└── "
    private let vertical = "│   "
    private let space = "    "

    init(
        fields: AttributeFields = .standard,
        filter: ElementFilter? = nil,
        maxDepth: Int = 3,
        showActions: Bool = false,
        useColor: Bool = true
    ) {
        self.fields = fields
        self.filter = filter
        self.maxDepth = maxDepth
        self.showActions = showActions
        self.useColor = useColor
    }

    // MARK: - Public API

    /// Print the tree starting from a root element
    func printTree(_ root: Accessibility.Element) {
        printNode(root, prefix: "", isLast: true, depth: 0)
    }

    /// Print the tree and return as a string
    func treeString(_ root: Accessibility.Element) -> String {
        var output = ""
        printNode(root, prefix: "", isLast: true, depth: 0, output: &output)
        return output
    }

    // MARK: - Private Implementation

    private func printNode(
        _ element: Accessibility.Element,
        prefix: String,
        isLast: Bool,
        depth: Int,
        output: inout String
    ) {
        // Check filter
        let passesFilter = filter?.matches(element) ?? true

        // Get children for recursion (needed even if this node is filtered)
        let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
        let children: [Accessibility.Element] = (try? childrenAttr()) ?? []

        // Get children that pass filter (or all if no filter)
        let matchingChildren: [Accessibility.Element]
        if let filter = filter {
            matchingChildren = children.filter { childPassesFilterOrHasMatchingDescendant($0, filter: filter, depth: depth + 1) }
        } else {
            matchingChildren = children
        }

        // Only print this node if it passes filter
        if passesFilter {
            let nodeText = formatElement(element)
            let connector = depth == 0 ? "" : (isLast ? lastBranch : branch)
            output += "\(prefix)\(connector)\(nodeText)\n"

            // Print actions if requested
            if showActions || fields.contains(.actions) {
                if let actions = try? element.supportedActions(), !actions.isEmpty {
                    let actionPrefix = depth == 0 ? "" : (isLast ? space : vertical)
                    let actionNames = actions.map { $0.name.value.replacingOccurrences(of: "AX", with: "") }
                    let actionsStr = Color.dim.wrap("actions: ", enabled: useColor) +
                                     Color.yellow.wrap(actionNames.joined(separator: ", "), enabled: useColor)
                    output += "\(prefix)\(actionPrefix)\(space)\(actionsStr)\n"
                }
            }
        }

        // Recurse into children
        guard depth < maxDepth else { return }

        let childPrefix: String
        if depth == 0 {
            childPrefix = ""
        } else if passesFilter {
            childPrefix = prefix + (isLast ? space : vertical)
        } else {
            childPrefix = prefix
        }

        for (index, child) in matchingChildren.enumerated() {
            let isLastChild = index == matchingChildren.count - 1
            printNode(child, prefix: childPrefix, isLast: isLastChild, depth: depth + 1, output: &output)
        }
    }

    private func printNode(
        _ element: Accessibility.Element,
        prefix: String,
        isLast: Bool,
        depth: Int
    ) {
        var output = ""
        printNode(element, prefix: prefix, isLast: isLast, depth: depth, output: &output)
        print(output, terminator: "")
    }

    /// Check if an element or any of its descendants passes the filter
    private func childPassesFilterOrHasMatchingDescendant(_ element: Accessibility.Element, filter: ElementFilter, depth: Int) -> Bool {
        if filter.matches(element) {
            return true
        }

        guard depth < maxDepth else { return false }

        let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
        guard let children: [Accessibility.Element] = try? childrenAttr() else { return false }

        for child in children {
            if childPassesFilterOrHasMatchingDescendant(child, filter: filter, depth: depth + 1) {
                return true
            }
        }

        return false
    }

    // MARK: - Element Formatting

    private func formatElement(_ element: Accessibility.Element) -> String {
        var parts: [String] = []

        // Role (always first, with color)
        if fields.contains(.role) {
            if let role = try? element.attribute(AXAttribute.role)() {
                let shortRole = role.replacingOccurrences(of: "AX", with: "")
                parts.append(Color.cyan.wrap(shortRole, enabled: useColor))
            }
        }

        // Subrole
        if fields.contains(.subrole) {
            if let subrole = try? element.attribute(AXAttribute.subrole)() {
                let shortSubrole = subrole.replacingOccurrences(of: "AX", with: "")
                parts.append(Color.blue.wrap("[\(shortSubrole)]", enabled: useColor))
            }
        }

        // Title
        if fields.contains(.title) {
            if let title = try? element.attribute(AXAttribute.title)() {
                let truncated = title.count > 40 ? String(title.prefix(40)) + "..." : title
                parts.append(Color.yellow.wrap("\"\(truncated)\"", enabled: useColor))
            }
        }

        // Identifier
        if fields.contains(.identifier) {
            if let id = try? element.attribute(AXAttribute.identifier)() {
                parts.append(Color.green.wrap("#\(id)", enabled: useColor))
            }
        }

        // Role description
        if fields.contains(.roleDescription) {
            if let roleDesc = try? element.attribute(AXAttribute.roleDescription)() {
                parts.append(Color.dim.wrap("(\(roleDesc))", enabled: useColor))
            }
        }

        // Value
        if fields.contains(.value) {
            if let value = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                let truncated = strValue.count > 30 ? String(strValue.prefix(30)) + "..." : strValue
                parts.append(Color.magenta.wrap("=\(truncated)", enabled: useColor))
            }
        }

        // Description
        if fields.contains(.description) {
            if let desc = try? element.attribute(AXAttribute.description)() {
                let truncated = desc.count > 30 ? String(desc.prefix(30)) + "..." : desc
                parts.append(Color.dim.wrap("desc:\"\(truncated)\"", enabled: useColor))
            }
        }

        // Enabled/Focused
        if fields.contains(.enabled) {
            if let enabled = try? element.attribute(AXAttribute.enabled)(), !enabled {
                parts.append(Color.red.wrap("[disabled]", enabled: useColor))
            }
        }

        if fields.contains(.focused) {
            if let focused = try? element.attribute(AXAttribute.focused)(), focused {
                parts.append(Color.brightGreen.wrap("[focused]", enabled: useColor))
            }
        }

        // Position/Size/Frame
        if fields.contains(.frame) {
            if let frame = try? element.attribute(AXAttribute.frame)() {
                parts.append(Color.dim.wrap("[\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))]", enabled: useColor))
            }
        } else {
            if fields.contains(.position) {
                if let pos = try? element.attribute(AXAttribute.position)() {
                    parts.append(Color.dim.wrap("@(\(Int(pos.x)),\(Int(pos.y)))", enabled: useColor))
                }
            }
            if fields.contains(.size) {
                if let size = try? element.attribute(AXAttribute.size)() {
                    parts.append(Color.dim.wrap("\(Int(size.width))x\(Int(size.height))", enabled: useColor))
                }
            }
        }

        // Help
        if fields.contains(.help) {
            if let help = try? element.attribute(AXAttribute.help)() {
                let truncated = help.count > 30 ? String(help.prefix(30)) + "..." : help
                parts.append(Color.dim.wrap("help:\"\(truncated)\"", enabled: useColor))
            }
        }

        // Child count
        if fields.contains(.childCount) {
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            if let count = try? childrenAttr.count(), count > 0 {
                parts.append(Color.dim.wrap("(\(count) children)", enabled: useColor))
            }
        }

        return parts.isEmpty ? Color.dim.wrap("(empty)", enabled: useColor) : parts.joined(separator: " ")
    }
}

// MARK: - ANSI Color Support

enum Color: String {
    case reset = "\u{001B}[0m"
    case dim = "\u{001B}[2m"
    case bold = "\u{001B}[1m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"
    case brightRed = "\u{001B}[91m"
    case brightGreen = "\u{001B}[92m"
    case brightYellow = "\u{001B}[93m"
    case brightBlue = "\u{001B}[94m"
    case brightMagenta = "\u{001B}[95m"
    case brightCyan = "\u{001B}[96m"

    func wrap(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        return "\(rawValue)\(text)\(Color.reset.rawValue)"
    }
}
