import Foundation
import AccessibilityControl

// MARK: - Element Filter

/// Filter for selecting accessibility elements based on criteria
struct ElementFilter {
    /// Role pattern to match (regex supported)
    var rolePattern: NSRegularExpression?

    /// Subrole pattern to match (regex supported)
    var subrolePattern: NSRegularExpression?

    /// Title pattern to match (regex supported)
    var titlePattern: NSRegularExpression?

    /// Identifier pattern to match (regex supported)
    var identifierPattern: NSRegularExpression?

    /// Required fields that must not be nil
    var requiredFields: Set<String>

    /// Fields that must be nil
    var excludedFields: Set<String>

    /// Whether filtering is case sensitive
    var caseSensitive: Bool

    init(
        rolePattern: String? = nil,
        subrolePattern: String? = nil,
        titlePattern: String? = nil,
        identifierPattern: String? = nil,
        requiredFields: [String] = [],
        excludedFields: [String] = [],
        caseSensitive: Bool = false
    ) throws {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]

        if let pattern = rolePattern {
            self.rolePattern = try NSRegularExpression(pattern: pattern, options: options)
        }
        if let pattern = subrolePattern {
            self.subrolePattern = try NSRegularExpression(pattern: pattern, options: options)
        }
        if let pattern = titlePattern {
            self.titlePattern = try NSRegularExpression(pattern: pattern, options: options)
        }
        if let pattern = identifierPattern {
            self.identifierPattern = try NSRegularExpression(pattern: pattern, options: options)
        }

        self.requiredFields = Set(requiredFields.map { normalizeFieldName($0) })
        self.excludedFields = Set(excludedFields.map { normalizeFieldName($0) })
        self.caseSensitive = caseSensitive
    }

    /// Check if an element matches this filter
    func matches(_ element: Accessibility.Element) -> Bool {
        // Check role pattern
        if let pattern = rolePattern {
            guard let role: String = try? element.attribute(AXAttribute.role)() else {
                return false
            }
            if !matchesPattern(pattern, in: role) {
                return false
            }
        }

        // Check subrole pattern
        if let pattern = subrolePattern {
            guard let subrole: String = try? element.attribute(AXAttribute.subrole)() else {
                return false
            }
            if !matchesPattern(pattern, in: subrole) {
                return false
            }
        }

        // Check title pattern
        if let pattern = titlePattern {
            guard let title: String = try? element.attribute(AXAttribute.title)() else {
                return false
            }
            if !matchesPattern(pattern, in: title) {
                return false
            }
        }

        // Check identifier pattern
        if let pattern = identifierPattern {
            guard let id: String = try? element.attribute(AXAttribute.identifier)() else {
                return false
            }
            if !matchesPattern(pattern, in: id) {
                return false
            }
        }

        // Check required fields (must not be nil)
        for field in requiredFields {
            if !hasValue(element, forField: field) {
                return false
            }
        }

        // Check excluded fields (must be nil)
        for field in excludedFields {
            if hasValue(element, forField: field) {
                return false
            }
        }

        return true
    }

    /// Check if element has a non-nil value for a field
    private func hasValue(_ element: Accessibility.Element, forField field: String) -> Bool {
        let attrName = field.hasPrefix("AX") ? field : "AX\(field)"

        switch attrName {
        case "AXRole":
            return (try? element.attribute(AXAttribute.role)()) != nil
        case "AXSubrole":
            return (try? element.attribute(AXAttribute.subrole)()) != nil
        case "AXTitle":
            return (try? element.attribute(AXAttribute.title)()) != nil
        case "AXIdentifier":
            return (try? element.attribute(AXAttribute.identifier)()) != nil
        case "AXDescription":
            return (try? element.attribute(AXAttribute.description)()) != nil
        case "AXValue":
            return (try? element.attribute(AXAttribute.value)()) != nil
        case "AXHelp":
            return (try? element.attribute(AXAttribute.help)()) != nil
        case "AXRoleDescription":
            return (try? element.attribute(AXAttribute.roleDescription)()) != nil
        case "AXEnabled":
            return (try? element.attribute(AXAttribute.enabled)()) != nil
        case "AXFocused":
            return (try? element.attribute(AXAttribute.focused)()) != nil
        case "AXPosition":
            return (try? element.attribute(AXAttribute.position)()) != nil
        case "AXSize":
            return (try? element.attribute(AXAttribute.size)()) != nil
        case "AXFrame":
            return (try? element.attribute(AXAttribute.frame)()) != nil
        case "AXChildren":
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            return (try? childrenAttr.count()) ?? 0 > 0
        default:
            // Try generic attribute read
            if let _: Any = try? element.attribute(.init(attrName))() {
                return true
            }
            return false
        }
    }

    private func matchesPattern(_ pattern: NSRegularExpression, in string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return pattern.firstMatch(in: string, options: [], range: range) != nil
    }

    /// Check if any filtering is active
    var isActive: Bool {
        rolePattern != nil ||
        subrolePattern != nil ||
        titlePattern != nil ||
        identifierPattern != nil ||
        !requiredFields.isEmpty ||
        !excludedFields.isEmpty
    }
}

// MARK: - Field Name Normalization

/// Normalize a field name to its canonical form
func normalizeFieldName(_ name: String) -> String {
    let lowercased = name.lowercased().trimmingCharacters(in: .whitespaces)
    switch lowercased {
    case "role": return "AXRole"
    case "subrole": return "AXSubrole"
    case "title": return "AXTitle"
    case "id", "identifier": return "AXIdentifier"
    case "desc", "description": return "AXDescription"
    case "value", "val": return "AXValue"
    case "help": return "AXHelp"
    case "roledesc", "roledescription", "role-description": return "AXRoleDescription"
    case "enabled": return "AXEnabled"
    case "focused": return "AXFocused"
    case "pos", "position": return "AXPosition"
    case "size": return "AXSize"
    case "frame": return "AXFrame"
    case "children": return "AXChildren"
    case "parent": return "AXParent"
    case "windows": return "AXWindows"
    default:
        // Assume it's already an AX name or add prefix
        return name.hasPrefix("AX") ? name : "AX\(name.capitalized)"
    }
}

// MARK: - Filter Help

extension ElementFilter {
    static var helpText: String {
        """
        FILTERING OPTIONS:
          --role PATTERN          Filter by role (regex, e.g., 'Button|Text')
          --subrole PATTERN       Filter by subrole (regex)
          --title PATTERN         Filter by title (regex)
          --id PATTERN            Filter by identifier (regex)
          --has FIELD,...         Only show elements where FIELD is not nil
          --without FIELD,...     Only show elements where FIELD is nil
          --case-sensitive        Make pattern matching case-sensitive

        FIELD NAMES for --has/--without:
          role, subrole, title, identifier (or id), description (or desc),
          value, help, enabled, focused, position, size, frame, children

        EXAMPLES:
          axdump dump 710 --role "Button"
          axdump dump 710 --role "Text.*" --has title
          axdump dump 710 --has identifier --without value
          axdump dump 710 --title "Save|Cancel" --case-sensitive
        """
    }
}
