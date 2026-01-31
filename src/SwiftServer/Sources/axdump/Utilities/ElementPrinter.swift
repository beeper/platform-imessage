import Foundation
import AccessibilityControl
import CoreGraphics

// MARK: - Element Printer

/// Formats accessibility elements for display
struct ElementPrinter {
    let fields: AttributeFields
    let verbosity: Int
    let useColor: Bool
    let maxLength: Int

    init(
        fields: AttributeFields = .standard,
        verbosity: Int = 1,
        useColor: Bool = true,
        maxLength: Int = 0
    ) {
        self.fields = fields
        self.verbosity = verbosity
        self.useColor = useColor
        self.maxLength = maxLength
    }

    // MARK: - Single Element Formatting

    /// Format an element as a single line
    func formatElement(_ element: Accessibility.Element, indent: Int = 0) -> String {
        let prefix = String(repeating: "  ", count: indent)
        var info: [String] = []

        if fields.contains(.role) {
            if let role = try? element.attribute(AXAttribute.role)() {
                info.append("role=\(role)")
            }
        }

        if fields.contains(.subrole) {
            if let subrole = try? element.attribute(AXAttribute.subrole)() {
                info.append("subrole=\(subrole)")
            }
        }

        if fields.contains(.roleDescription) {
            if let roleDesc = try? element.attribute(AXAttribute.roleDescription)() {
                info.append("roleDesc=\"\(roleDesc)\"")
            }
        }

        if fields.contains(.title) {
            if let title = try? element.attribute(AXAttribute.title)() {
                let truncated = truncate(title, to: 50)
                info.append("title=\"\(truncated)\"")
            }
        }

        if fields.contains(.identifier) {
            if let id = try? element.attribute(AXAttribute.identifier)() {
                info.append("id=\"\(id)\"")
            }
        }

        if fields.contains(.description) {
            if let desc = try? element.attribute(AXAttribute.description)() {
                let truncated = truncate(desc, to: 50)
                info.append("desc=\"\(truncated)\"")
            }
        }

        if fields.contains(.value) {
            if let value = try? element.attribute(AXAttribute.value)() {
                let strValue = String(describing: value)
                let truncated = truncate(strValue, to: 50)
                info.append("value=\"\(truncated)\"")
            }
        }

        if fields.contains(.enabled) {
            if let enabled = try? element.attribute(AXAttribute.enabled)() {
                info.append("enabled=\(enabled)")
            }
        }

        if fields.contains(.focused) {
            if let focused = try? element.attribute(AXAttribute.focused)() {
                info.append("focused=\(focused)")
            }
        }

        if fields.contains(.position) {
            if let pos = try? element.attribute(AXAttribute.position)() {
                info.append("pos=(\(Int(pos.x)),\(Int(pos.y)))")
            }
        }

        if fields.contains(.size) {
            if let size = try? element.attribute(AXAttribute.size)() {
                info.append("size=(\(Int(size.width))x\(Int(size.height)))")
            }
        }

        if fields.contains(.frame) {
            if let frame = try? element.attribute(AXAttribute.frame)() {
                info.append("frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)))")
            }
        }

        if fields.contains(.help) {
            if let help = try? element.attribute(AXAttribute.help)() {
                let truncated = truncate(help, to: 50)
                info.append("help=\"\(truncated)\"")
            }
        }

        if fields.contains(.childCount) {
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            if let count = try? childrenAttr.count() {
                info.append("children=\(count)")
            }
        }

        let infoStr = info.isEmpty ? "(no attributes)" : info.joined(separator: " ")
        var result = "\(prefix)\(infoStr)"

        if verbosity >= 2 || fields.contains(.actions) {
            if let actions = try? element.supportedActions(), !actions.isEmpty {
                let actionNames = actions.map { $0.name.value.replacingOccurrences(of: "AX", with: "") }
                result += "\n\(prefix)  actions: \(actionNames.joined(separator: ", "))"
            }
        }

        return result
    }

    /// Format element for JSON output
    func formatElementForJSON(_ element: Accessibility.Element) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let role: String = try? element.attribute(AXAttribute.role)() {
            dict["role"] = role
        }
        if let subrole: String = try? element.attribute(AXAttribute.subrole)() {
            dict["subrole"] = subrole
        }
        if let title: String = try? element.attribute(AXAttribute.title)() {
            dict["title"] = title
        }
        if let id: String = try? element.attribute(AXAttribute.identifier)() {
            dict["identifier"] = id
        }
        if let desc: String = try? element.attribute(AXAttribute.description)() {
            dict["description"] = desc
        }
        if let value = try? element.attribute(AXAttribute.value)() {
            dict["value"] = formatValueForJSON(value)
        }
        if let enabled: Bool = try? element.attribute(AXAttribute.enabled)() {
            dict["enabled"] = enabled
        }
        if let focused: Bool = try? element.attribute(AXAttribute.focused)() {
            dict["focused"] = focused
        }
        if let frame = try? element.attribute(AXAttribute.frame)() {
            dict["frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.width,
                "height": frame.height
            ]
        }

        return dict
    }

    // MARK: - Value Formatting

    /// Format a value for display
    func formatValue(_ value: Any) -> String {
        switch value {
        case let element as Accessibility.Element:
            var parts: [String] = ["<Element"]
            if let role: String = try? element.attribute(AXAttribute.role)() {
                parts.append("role=\(role)")
            }
            if let title: String = try? element.attribute(AXAttribute.title)() {
                parts.append("title=\"\(title)\"")
            }
            if let id: String = try? element.attribute(AXAttribute.identifier)() {
                parts.append("id=\"\(id)\"")
            }
            parts.append(">")
            return parts.joined(separator: " ")

        case let elements as [Accessibility.Element]:
            var lines: [String] = ["[\(elements.count) elements]"]
            for (index, element) in elements.enumerated() {
                var parts: [String] = ["  [\(index)]"]
                if let role: String = try? element.attribute(AXAttribute.role)() {
                    parts.append("role=\(role)")
                }
                if let title: String = try? element.attribute(AXAttribute.title)() {
                    parts.append("title=\"\(title)\"")
                }
                if let id: String = try? element.attribute(AXAttribute.identifier)() {
                    parts.append("id=\"\(id)\"")
                }
                lines.append(parts.joined(separator: " "))
            }
            return lines.joined(separator: "\n")

        case let structValue as Accessibility.Struct:
            switch structValue {
            case .point(let point):
                return "(\(point.x), \(point.y))"
            case .size(let size):
                return "\(size.width) x \(size.height)"
            case .rect(let rect):
                return "origin=(\(rect.origin.x), \(rect.origin.y)) size=(\(rect.width) x \(rect.height))"
            case .range(let range):
                return "\(range.lowerBound)..<\(range.upperBound)"
            case .error(let error):
                return "Error: \(error)"
            }

        case let point as CGPoint:
            return "(\(point.x), \(point.y))"

        case let size as CGSize:
            return "\(size.width) x \(size.height)"

        case let rect as CGRect:
            return "origin=(\(rect.origin.x), \(rect.origin.y)) size=(\(rect.width) x \(rect.height))"

        case let array as [Any]:
            return array.map { formatValue($0) }.joined(separator: ", ")

        case let dict as [String: Any]:
            return dict.map { "\($0.key): \(formatValue($0.value))" }.joined(separator: ", ")

        default:
            let str = String(describing: value)
            return maxLength > 0 && str.count > maxLength ? String(str.prefix(maxLength)) + "..." : str
        }
    }

    /// Format a value for JSON serialization
    func formatValueForJSON(_ value: Any) -> Any {
        switch value {
        case let element as Accessibility.Element:
            return formatElementForJSON(element)

        case let elements as [Accessibility.Element]:
            return elements.map { formatElementForJSON($0) }

        case let structValue as Accessibility.Struct:
            switch structValue {
            case .point(let point):
                return ["x": point.x, "y": point.y]
            case .size(let size):
                return ["width": size.width, "height": size.height]
            case .rect(let rect):
                return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
            case .range(let range):
                return ["start": range.lowerBound, "end": range.upperBound]
            case .error(let error):
                return ["error": String(describing: error)]
            }

        case let point as CGPoint:
            return ["x": point.x, "y": point.y]

        case let size as CGSize:
            return ["width": size.width, "height": size.height]

        case let rect as CGRect:
            return ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]

        case let array as [Any]:
            return array.map { formatValueForJSON($0) }

        case let dict as [String: Any]:
            return dict.mapValues { formatValueForJSON($0) }

        case let str as String:
            return str

        case let num as NSNumber:
            return num

        case let bool as Bool:
            return bool

        default:
            return String(describing: value)
        }
    }

    // MARK: - Helpers

    private func truncate(_ string: String, to maxLength: Int) -> String {
        let limit = self.maxLength > 0 ? min(maxLength, self.maxLength) : maxLength
        return string.count > limit ? String(string.prefix(limit)) + "..." : string
    }
}

// MARK: - Element Path Computation

/// Compute the path from the application root to a given element
func computeElementPath(_ element: Accessibility.Element, appElement: Accessibility.Element) -> (path: String, chain: String) {
    var ancestors: [Accessibility.Element] = []
    var current = element

    while true {
        ancestors.append(current)
        guard let parent: Accessibility.Element = try? current.attribute(.init("AXParent"))() else {
            break
        }
        if parent == appElement {
            break
        }
        current = parent
    }

    ancestors.reverse()

    var indices: [Int] = []
    var chainParts: [String] = []

    var parentForIndex = appElement
    for ancestor in ancestors {
        let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = parentForIndex.attribute(.init("AXChildren"))
        if let children: [Accessibility.Element] = try? childrenAttr() {
            if let index = children.firstIndex(of: ancestor) {
                indices.append(index)
            } else {
                indices.append(-1)
            }
        } else {
            indices.append(-1)
        }

        var desc = ""
        if let role: String = try? ancestor.attribute(AXAttribute.role)() {
            desc = role.replacingOccurrences(of: "AX", with: "")
        }
        if let id: String = try? ancestor.attribute(AXAttribute.identifier)() {
            desc += "[\(id)]"
        } else if let title: String = try? ancestor.attribute(AXAttribute.title)() {
            let truncated = title.count > 20 ? String(title.prefix(20)) + "..." : title
            desc += "[\"\(truncated)\"]"
        }
        if desc.isEmpty {
            desc = "?"
        }
        chainParts.append(desc)

        parentForIndex = ancestor
    }

    let pathString = indices.map { $0 >= 0 ? String($0) : "?" }.joined(separator: ".")
    let chainString = chainParts.joined(separator: " > ")

    return (pathString, chainString)
}

// MARK: - Element Navigation

/// Navigate to an element via dot-separated child indices
func navigateToPath(from element: Accessibility.Element, path: String) throws -> Accessibility.Element {
    var current = element
    let indices = path.split(separator: ".").compactMap { Int($0) }

    for (step, index) in indices.enumerated() {
        let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = current.attribute(.init("AXChildren"))
        guard let children: [Accessibility.Element] = try? childrenAttr() else {
            throw NavigationError.noChildren(step: step)
        }
        guard index >= 0 && index < children.count else {
            throw NavigationError.indexOutOfRange(index: index, step: step, count: children.count)
        }
        current = children[index]
    }

    return current
}

/// Navigate to a single child by index
func navigateToChild(from element: Accessibility.Element, index: Int) throws -> Accessibility.Element {
    let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
    guard let children: [Accessibility.Element] = try? childrenAttr() else {
        throw NavigationError.noChildren(step: 0)
    }
    guard index >= 0 && index < children.count else {
        throw NavigationError.indexOutOfRange(index: index, step: 0, count: children.count)
    }
    return children[index]
}

enum NavigationError: Error, CustomStringConvertible {
    case noChildren(step: Int)
    case indexOutOfRange(index: Int, step: Int, count: Int)

    var description: String {
        switch self {
        case .noChildren(let step):
            return "Element at step \(step) has no children"
        case .indexOutOfRange(let index, let step, let count):
            return "Child index \(index) at step \(step) out of range (0..<\(count))"
        }
    }
}
