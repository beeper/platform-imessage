import Foundation
import AccessibilityControl
import CoreGraphics

// MARK: - Attribute Names

/// Common accessibility attribute names with type information
enum AXAttribute {
    static let frame: Accessibility.Attribute<CGRect>.Name = .init("AXFrame")
    static let position: Accessibility.Attribute<CGPoint>.Name = .init("AXPosition")
    static let size: Accessibility.Attribute<CGSize>.Name = .init("AXSize")
    static let role: Accessibility.Attribute<String>.Name = .init("AXRole")
    static let subrole: Accessibility.Attribute<String>.Name = .init("AXSubrole")
    static let roleDescription: Accessibility.Attribute<String>.Name = .init("AXRoleDescription")
    static let title: Accessibility.Attribute<String>.Name = .init("AXTitle")
    static let identifier: Accessibility.Attribute<String>.Name = .init("AXIdentifier")
    static let description: Accessibility.Attribute<String>.Name = .init("AXDescription")
    static let help: Accessibility.Attribute<String>.Name = .init("AXHelp")
    static let value: Accessibility.Attribute<Any>.Name = .init("AXValue")
    static let enabled: Accessibility.Attribute<Bool>.Name = .init("AXEnabled")
    static let focused: Accessibility.Attribute<Bool>.Name = .init("AXFocused")
    static let children: Accessibility.Attribute<[Accessibility.Element]>.Name = .init("AXChildren")
    static let parent: Accessibility.Attribute<Accessibility.Element>.Name = .init("AXParent")
    static let windows: Accessibility.Attribute<[Accessibility.Element]>.Name = .init("AXWindows")
    static let focusedWindow: Accessibility.Attribute<Accessibility.Element>.Name = .init("AXFocusedWindow")
    static let focusedUIElement: Accessibility.Attribute<Accessibility.Element>.Name = .init("AXFocusedUIElement")
    static let mainWindow: Accessibility.Attribute<Accessibility.Element>.Name = .init("AXMainWindow")
}

// MARK: - Attribute Field Selection

/// Option set for selecting which attribute fields to display
struct AttributeFields: OptionSet {
    let rawValue: Int

    static let role            = AttributeFields(rawValue: 1 << 0)
    static let roleDescription = AttributeFields(rawValue: 1 << 1)
    static let title           = AttributeFields(rawValue: 1 << 2)
    static let identifier      = AttributeFields(rawValue: 1 << 3)
    static let value           = AttributeFields(rawValue: 1 << 4)
    static let description     = AttributeFields(rawValue: 1 << 5)
    static let enabled         = AttributeFields(rawValue: 1 << 6)
    static let focused         = AttributeFields(rawValue: 1 << 7)
    static let position        = AttributeFields(rawValue: 1 << 8)
    static let size            = AttributeFields(rawValue: 1 << 9)
    static let frame           = AttributeFields(rawValue: 1 << 10)
    static let help            = AttributeFields(rawValue: 1 << 11)
    static let subrole         = AttributeFields(rawValue: 1 << 12)
    static let childCount      = AttributeFields(rawValue: 1 << 13)
    static let actions         = AttributeFields(rawValue: 1 << 14)

    // Presets
    static let minimal: AttributeFields = [.role, .title, .identifier]
    static let standard: AttributeFields = [.role, .roleDescription, .title, .identifier, .value, .description]
    static let full: AttributeFields = [
        .role, .roleDescription, .title, .identifier, .value,
        .description, .enabled, .focused, .position, .size, .frame, .help, .subrole
    ]
    static let all: AttributeFields = [
        .role, .roleDescription, .title, .identifier, .value,
        .description, .enabled, .focused, .position, .size, .frame, .help, .subrole,
        .childCount, .actions
    ]

    /// Parse a comma-separated field specification string
    static func parse(_ string: String) -> AttributeFields {
        var fields: AttributeFields = []
        for name in string.lowercased().split(separator: ",") {
            switch name.trimmingCharacters(in: .whitespaces) {
            case "role": fields.insert(.role)
            case "roledescription", "role-description", "roledesc": fields.insert(.roleDescription)
            case "title": fields.insert(.title)
            case "identifier", "id": fields.insert(.identifier)
            case "value", "val": fields.insert(.value)
            case "description", "desc": fields.insert(.description)
            case "enabled": fields.insert(.enabled)
            case "focused": fields.insert(.focused)
            case "position", "pos": fields.insert(.position)
            case "size": fields.insert(.size)
            case "frame": fields.insert(.frame)
            case "help": fields.insert(.help)
            case "subrole": fields.insert(.subrole)
            case "children", "childcount", "child-count": fields.insert(.childCount)
            case "actions": fields.insert(.actions)
            // Presets
            case "minimal": fields.formUnion(.minimal)
            case "standard": fields.formUnion(.standard)
            case "full": fields.formUnion(.full)
            case "all": fields.formUnion(.all)
            default: break
            }
        }
        return fields.isEmpty ? .standard : fields
    }

    /// Help text describing available field options
    static var helpText: String {
        """
        FIELD OPTIONS:
          Presets:
            minimal   - role, title, identifier
            standard  - role, roleDescription, title, identifier, value, description (default)
            full      - all basic fields
            all       - all fields including childCount and actions

          Individual fields (comma-separated):
            role, subrole, roleDescription (or roledesc), title,
            identifier (or id), value (or val), description (or desc),
            enabled, focused, position (or pos), size, frame, help,
            childCount (or children), actions

          Examples:
            -f minimal
            -f role,title,value
            -f standard,actions
        """
    }
}
