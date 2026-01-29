import Foundation

// MARK: - Common Accessibility Roles

/// Standard macOS accessibility roles (AXRole values)
enum AXRoles {
    /// All known roles for reference and help text
    static let all: [String: String] = [
        // Core UI Elements
        "AXApplication": "Application root element",
        "AXWindow": "Window container",
        "AXSheet": "Sheet dialog",
        "AXDrawer": "Drawer panel",
        "AXDialog": "Dialog window",

        // Buttons & Controls
        "AXButton": "Push button",
        "AXRadioButton": "Radio button (single selection)",
        "AXCheckBox": "Checkbox (toggle)",
        "AXPopUpButton": "Pop-up button (dropdown)",
        "AXMenuButton": "Menu button",
        "AXDisclosureTriangle": "Disclosure triangle (expand/collapse)",
        "AXIncrementor": "Stepper control",
        "AXSlider": "Slider control",
        "AXColorWell": "Color picker well",

        // Text Elements
        "AXStaticText": "Static text label",
        "AXTextField": "Text input field",
        "AXTextArea": "Multi-line text area",
        "AXSecureTextField": "Password field",
        "AXSearchField": "Search input field",
        "AXComboBox": "Combo box (text + dropdown)",

        // Menus
        "AXMenuBar": "Application menu bar",
        "AXMenu": "Menu container",
        "AXMenuItem": "Menu item",
        "AXMenuBarItem": "Menu bar item",

        // Lists & Tables
        "AXList": "List container",
        "AXTable": "Table with rows/columns",
        "AXOutline": "Outline (hierarchical list)",
        "AXBrowser": "Column browser (like Finder)",
        "AXRow": "Table/list row",
        "AXColumn": "Table column",
        "AXCell": "Table cell",

        // Groups & Containers
        "AXGroup": "Generic grouping element",
        "AXScrollArea": "Scrollable area",
        "AXSplitGroup": "Split view container",
        "AXSplitter": "Split view divider",
        "AXTabGroup": "Tab container",
        "AXToolbar": "Toolbar container",
        "AXLayoutArea": "Layout area",
        "AXLayoutItem": "Layout item",
        "AXMatte": "Matte (background)",
        "AXRulerMarker": "Ruler marker",

        // Media & Images
        "AXImage": "Image element",
        "AXValueIndicator": "Value indicator (progress)",
        "AXProgressIndicator": "Progress bar",
        "AXBusyIndicator": "Busy/loading indicator",
        "AXRelevanceIndicator": "Relevance indicator",
        "AXLevelIndicator": "Level indicator",

        // Special Elements
        "AXLink": "Hyperlink",
        "AXHelpTag": "Help tooltip",
        "AXScrollBar": "Scroll bar",
        "AXHandle": "Resize handle",
        "AXGrowArea": "Window grow area",
        "AXRuler": "Ruler",
        "AXGrid": "Grid layout",
        "AXWebArea": "Web content area",

        // System UI
        "AXDockItem": "Dock item",
        "AXSystemWide": "System-wide element",
    ]

    /// Most commonly used roles
    static let common: [String] = [
        "AXButton", "AXStaticText", "AXTextField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider",
        "AXWindow", "AXGroup", "AXScrollArea", "AXTable", "AXList",
        "AXRow", "AXCell", "AXImage", "AXLink", "AXMenu", "AXMenuItem",
        "AXToolbar", "AXTabGroup", "AXWebArea"
    ]
}

// MARK: - Common Accessibility Subroles

/// Standard macOS accessibility subroles (AXSubrole values)
enum AXSubroles {
    /// All known subroles for reference and help text
    static let all: [String: String] = [
        // Window Subroles
        "AXStandardWindow": "Standard window",
        "AXDialog": "Dialog window",
        "AXSystemDialog": "System dialog",
        "AXFloatingWindow": "Floating window",
        "AXFullScreenWindow": "Full screen window",

        // Button Subroles
        "AXCloseButton": "Window close button",
        "AXMinimizeButton": "Window minimize button",
        "AXZoomButton": "Window zoom button",
        "AXFullScreenButton": "Full screen button",
        "AXToolbarButton": "Toolbar button",
        "AXSecureTextField": "Secure text field",
        "AXSearchField": "Search field",

        // Table Subroles
        "AXSortButton": "Sort button (table header)",
        "AXTableRow": "Table row",
        "AXOutlineRow": "Outline row",

        // Text Subroles
        "AXTextAttachment": "Text attachment",
        "AXTextLink": "Text link",

        // Menu Subroles
        "AXMenuBarItem": "Menu bar item",
        "AXApplicationDockItem": "Application dock item",
        "AXDocumentDockItem": "Document dock item",
        "AXFolderDockItem": "Folder dock item",
        "AXMinimizedWindowDockItem": "Minimized window dock item",
        "AXURLDockItem": "URL dock item",
        "AXDockExtraDockItem": "Dock extra item",
        "AXTrashDockItem": "Trash dock item",
        "AXSeparatorDockItem": "Separator dock item",
        "AXProcessSwitcherList": "Process switcher list",

        // Content Subroles
        "AXContentList": "Content list",
        "AXDefinitionList": "Definition list",
        "AXDescriptionList": "Description list",

        // Decorator Subroles
        "AXDecrementArrow": "Decrement arrow",
        "AXIncrementArrow": "Increment arrow",
        "AXDecrementPage": "Decrement page",
        "AXIncrementPage": "Increment page",

        // Timeline Subroles
        "AXTimeline": "Timeline",
        "AXRatingIndicator": "Rating indicator",

        // Accessibility Subroles
        "AXUnknown": "Unknown subrole",
        "AXToggle": "Toggle button",
        "AXSwitch": "Switch control",
    ]

    /// Most commonly used subroles
    static let common: [String] = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton",
        "AXFullScreenButton", "AXToolbarButton", "AXSearchField",
        "AXTableRow", "AXOutlineRow", "AXTextLink", "AXToggle", "AXSwitch"
    ]
}

// MARK: - Common Accessibility Actions

/// Standard macOS accessibility actions (AXAction values)
enum AXActions {
    /// All known actions for reference and help text
    static let all: [String: String] = [
        // Primary Actions
        "AXPress": "Activate/click the element (buttons, links)",
        "AXIncrement": "Increase value (sliders, steppers)",
        "AXDecrement": "Decrease value (sliders, steppers)",
        "AXConfirm": "Confirm/submit (dialogs, forms)",
        "AXCancel": "Cancel operation",
        "AXPick": "Pick/select item (menus, pickers)",

        // Window Actions
        "AXRaise": "Bring window to front",

        // Menu Actions
        "AXShowMenu": "Show context/popup menu",

        // UI Actions
        "AXShowAlternateUI": "Show alternate UI",
        "AXShowDefaultUI": "Show default UI",

        // Scroll Actions
        "AXScrollLeftByPage": "Scroll left by page",
        "AXScrollRightByPage": "Scroll right by page",
        "AXScrollUpByPage": "Scroll up by page",
        "AXScrollDownByPage": "Scroll down by page",

        // Deletion Actions
        "AXDelete": "Delete element or content",
    ]

    /// Most commonly used actions
    static let common: [String] = [
        "AXPress", "AXIncrement", "AXDecrement", "AXConfirm",
        "AXCancel", "AXPick", "AXRaise", "AXShowMenu"
    ]
}

// MARK: - Common Accessibility Notifications

/// Standard macOS accessibility notifications
enum AXNotifications {
    /// All known notifications for reference
    static let all: [String] = [
        "AXValueChanged",
        "AXUIElementDestroyed",
        "AXSelectedTextChanged",
        "AXSelectedChildrenChanged",
        "AXFocusedUIElementChanged",
        "AXFocusedWindowChanged",
        "AXApplicationActivated",
        "AXApplicationDeactivated",
        "AXWindowCreated",
        "AXWindowMoved",
        "AXWindowResized",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
        "AXDrawerCreated",
        "AXSheetCreated",
        "AXMenuOpened",
        "AXMenuClosed",
        "AXMenuItemSelected",
        "AXTitleChanged",
        "AXResized",
        "AXMoved",
        "AXCreated",
        "AXLayoutChanged",
        "AXSelectedCellsChanged",
        "AXUnitsChanged",
        "AXSelectedColumnsChanged",
        "AXSelectedRowsChanged",
        "AXRowCountChanged",
        "AXRowExpanded",
        "AXRowCollapsed",
    ]
}

// MARK: - Help Text Generators

extension AXRoles {
    static func helpText() -> String {
        var lines: [String] = ["COMMON ROLES:"]
        for role in common {
            if let desc = all[role] {
                let shortRole = role.replacingOccurrences(of: "AX", with: "")
                lines.append("  \(shortRole.padding(toLength: 20, withPad: " ", startingAt: 0)) \(desc)")
            }
        }
        lines.append("")
        lines.append("Use --list-roles for all \(all.count) known roles")
        return lines.joined(separator: "\n")
    }

    static func fullHelpText() -> String {
        var lines: [String] = ["ALL KNOWN ROLES:"]
        for (role, desc) in all.sorted(by: { $0.key < $1.key }) {
            let shortRole = role.replacingOccurrences(of: "AX", with: "")
            lines.append("  \(shortRole.padding(toLength: 25, withPad: " ", startingAt: 0)) \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}

extension AXSubroles {
    static func helpText() -> String {
        var lines: [String] = ["COMMON SUBROLES:"]
        for subrole in common {
            if let desc = all[subrole] {
                let shortSubrole = subrole.replacingOccurrences(of: "AX", with: "")
                lines.append("  \(shortSubrole.padding(toLength: 20, withPad: " ", startingAt: 0)) \(desc)")
            }
        }
        lines.append("")
        lines.append("Use --list-subroles for all \(all.count) known subroles")
        return lines.joined(separator: "\n")
    }

    static func fullHelpText() -> String {
        var lines: [String] = ["ALL KNOWN SUBROLES:"]
        for (subrole, desc) in all.sorted(by: { $0.key < $1.key }) {
            let shortSubrole = subrole.replacingOccurrences(of: "AX", with: "")
            lines.append("  \(shortSubrole.padding(toLength: 25, withPad: " ", startingAt: 0)) \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}

extension AXActions {
    static func helpText() -> String {
        var lines: [String] = ["COMMON ACTIONS:"]
        for action in common {
            if let desc = all[action] {
                let shortAction = action.replacingOccurrences(of: "AX", with: "")
                lines.append("  \(shortAction.padding(toLength: 15, withPad: " ", startingAt: 0)) \(desc)")
            }
        }
        lines.append("")
        lines.append("Use --list-actions for all \(all.count) known actions")
        return lines.joined(separator: "\n")
    }

    static func fullHelpText() -> String {
        var lines: [String] = ["ALL KNOWN ACTIONS:"]
        for (action, desc) in all.sorted(by: { $0.key < $1.key }) {
            let shortAction = action.replacingOccurrences(of: "AX", with: "")
            lines.append("  \(shortAction.padding(toLength: 20, withPad: " ", startingAt: 0)) \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}
