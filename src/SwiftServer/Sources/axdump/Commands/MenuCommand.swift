import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit

extension AXDump {
    struct Menu: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Explore and activate menu bar items",
            discussion: """
                List menu bar items, explore menu hierarchies, and trigger menu actions
                via accessibility APIs. This works even when the app isn't frontmost.

                MENU PATHS:
                  Menu paths use '>' to separate menu levels.
                  Examples: "File", "File > New", "Edit > Find > Find..."

                EXAMPLES:
                  axdump menu 710                         List top-level menus
                  axdump menu 710 -m "File"               Show File menu items
                  axdump menu 710 -m "File > New"         Show New submenu
                  axdump menu 710 -m "Edit > Copy" -x     Execute Edit > Copy
                  axdump menu 710 -m "File > Save" -x     Execute File > Save
                  axdump menu 710 --search "paste"        Search all menus for "paste"
                  axdump menu 710 -m "View" --tree        Show full menu tree
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Option(name: [.customShort("m"), .long], help: "Menu path (e.g., 'File', 'File > Save', 'Edit > Find > Find...')")
        var menu: String?

        @Flag(name: [.customShort("x"), .long], help: "Execute/activate the menu item")
        var execute: Bool = false

        @Option(name: .long, help: "Search all menus for items matching this pattern (case-insensitive)")
        var search: String?

        @Flag(name: .long, help: "Show full menu tree (can be slow for large menus)")
        var tree: Bool = false

        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose: Bool = false

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false

        func run() throws {
            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                throw ExitCode.failure
            }

            let appElement = Accessibility.Element(pid: pid)

            // Get the menu bar
            guard let menuBar = getMenuBar(appElement) else {
                print("Error: Could not find menu bar for PID \(pid)")
                throw ExitCode.failure
            }

            // Search mode
            if let searchPattern = search {
                try searchMenus(menuBar: menuBar, pattern: searchPattern)
                return
            }

            // If no menu specified, list top-level menus
            guard let menuPath = menu else {
                try listTopLevelMenus(menuBar: menuBar)
                return
            }

            // Parse menu path and navigate
            let pathComponents = menuPath.split(separator: ">").map { String($0).trimmingCharacters(in: .whitespaces) }

            guard let targetItem = try navigateToMenuItem(menuBar: menuBar, path: pathComponents) else {
                print("Error: Could not find menu item '\(menuPath)'")
                throw ExitCode.failure
            }

            if execute {
                // Execute the menu item
                try executeMenuItem(targetItem, path: menuPath)
            } else if tree {
                // Show full tree
                try showMenuTree(targetItem, indent: 0)
            } else {
                // Show children of this menu/item
                try showMenuContents(targetItem, path: menuPath)
            }
        }

        // MARK: - Menu Bar Access

        private func getMenuBar(_ appElement: Accessibility.Element) -> Accessibility.Element? {
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = appElement.attribute(.init("AXChildren"))
            guard let children = try? childrenAttr() else { return nil }

            for child in children {
                if let role: String = try? child.attribute(AXAttribute.role)(),
                   role == "AXMenuBar" {
                    return child
                }
            }
            return nil
        }

        // MARK: - List Menus

        private func listTopLevelMenus(menuBar: Accessibility.Element) throws {
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = menuBar.attribute(.init("AXChildren"))
            guard let menuBarItems = try? childrenAttr() else {
                print("Could not read menu bar items")
                return
            }

            print("Menu Bar Items:")
            print(String(repeating: "-", count: 50))

            for (index, item) in menuBarItems.enumerated() {
                let title = (try? item.attribute(AXAttribute.title)()) ?? "(untitled)"
                let enabled = (try? item.attribute(AXAttribute.enabled)()) ?? true

                var line = "[\(index)] \(title)"
                if !enabled {
                    line += " (disabled)"
                }
                print(line)
            }

            print()
            print("Use -m \"<menu name>\" to explore a menu")
        }

        // MARK: - Navigate to Menu Item

        private func navigateToMenuItem(menuBar: Accessibility.Element, path: [String]) throws -> Accessibility.Element? {
            var current: Accessibility.Element = menuBar

            for (level, name) in path.enumerated() {
                // Get children of current element
                let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = current.attribute(.init("AXChildren"))
                guard let children = try? childrenAttr() else {
                    if verbose {
                        print("Warning: No children at level \(level)")
                    }
                    return nil
                }

                // Find matching child
                var found: Accessibility.Element?
                for child in children {
                    let childTitle = (try? child.attribute(AXAttribute.title)()) ?? ""
                    if childTitle.lowercased() == name.lowercased() ||
                       childTitle.lowercased().hasPrefix(name.lowercased()) {
                        found = child
                        break
                    }
                }

                guard let nextElement = found else {
                    if verbose {
                        print("Warning: Could not find '\(name)' at level \(level)")
                        print("Available items:")
                        for child in children {
                            let childTitle = (try? child.attribute(AXAttribute.title)()) ?? "(untitled)"
                            print("  - \(childTitle)")
                        }
                    }
                    return nil
                }

                // If this is a menu bar item or menu item with children, we need to get its menu
                let role = (try? nextElement.attribute(AXAttribute.role)()) ?? ""

                if role == "AXMenuBarItem" || role == "AXMenuItem" {
                    // Check if it has a submenu
                    let subChildrenAttr: Accessibility.Attribute<[Accessibility.Element]> = nextElement.attribute(.init("AXChildren"))
                    if let subChildren = try? subChildrenAttr(), !subChildren.isEmpty {
                        // Get the submenu (first child that's a menu)
                        for subChild in subChildren {
                            let subRole = (try? subChild.attribute(AXAttribute.role)()) ?? ""
                            if subRole == "AXMenu" {
                                current = subChild
                                break
                            }
                        }
                    } else {
                        // This is a leaf item
                        current = nextElement
                    }
                } else {
                    current = nextElement
                }

                // If this is the last item in the path, return the menu item itself (not the submenu)
                if level == path.count - 1 {
                    return nextElement
                }
            }

            return current
        }

        // MARK: - Show Menu Contents

        private func showMenuContents(_ element: Accessibility.Element, path: String) throws {
            let role = (try? element.attribute(AXAttribute.role)()) ?? ""

            // If it's a menu item, get its submenu
            var menuElement = element
            if role == "AXMenuBarItem" || role == "AXMenuItem" {
                let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
                if let children = try? childrenAttr() {
                    for child in children {
                        let childRole = (try? child.attribute(AXAttribute.role)()) ?? ""
                        if childRole == "AXMenu" {
                            menuElement = child
                            break
                        }
                    }
                }
            }

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = menuElement.attribute(.init("AXChildren"))
            guard let items = try? childrenAttr() else {
                print("Menu '\(path)' has no items")
                return
            }

            print("Menu: \(path)")
            print(String(repeating: "-", count: 50))

            for (index, item) in items.enumerated() {
                let itemRole = (try? item.attribute(AXAttribute.role)()) ?? ""

                // Skip menu itself
                if itemRole == "AXMenu" { continue }

                let title = (try? item.attribute(AXAttribute.title)()) ?? ""
                let enabled = (try? item.attribute(AXAttribute.enabled)()) ?? true
                let shortcutAttr: Accessibility.Attribute<String> = item.attribute(.init("AXMenuItemCmdChar"))
                let shortcut = (try? shortcutAttr()) ?? ""
                let modifiersAttr: Accessibility.Attribute<Int> = item.attribute(.init("AXMenuItemCmdModifiers"))
                let modifiers = (try? modifiersAttr()) ?? 0

                // Check if has submenu
                let subChildrenAttr: Accessibility.Attribute<[Accessibility.Element]> = item.attribute(.init("AXChildren"))
                let hasSubmenu = (try? subChildrenAttr())?.contains { (try? $0.attribute(AXAttribute.role)()) == "AXMenu" } ?? false

                // Format line
                var line = ""

                if title.isEmpty {
                    line = "[\(index)] ─────────────────"  // Separator
                } else {
                    line = "[\(index)] \(title)"

                    if hasSubmenu {
                        line += " ▶"
                    }

                    if !shortcut.isEmpty {
                        let modStr = formatModifiers(modifiers)
                        line += "  (\(modStr)\(shortcut))"
                    }

                    if !enabled {
                        line += " [disabled]"
                    }
                }

                print(line)
            }

            print()
            print("Use -m \"\(path) > <item>\" to explore submenus")
            print("Use -m \"\(path) > <item>\" -x to execute an action")
        }

        // MARK: - Execute Menu Item

        private func executeMenuItem(_ item: Accessibility.Element, path: String) throws {
            let title = (try? item.attribute(AXAttribute.title)()) ?? path
            let enabled = (try? item.attribute(AXAttribute.enabled)()) ?? true

            guard enabled else {
                print("Error: Menu item '\(title)' is disabled")
                throw ExitCode.failure
            }

            // Perform the press action
            let action = item.action(.init("AXPress"))
            try action()

            print("Executed: \(path)")

            if verbose {
                print("  Title: \(title)")
            }
        }

        // MARK: - Show Menu Tree

        private func showMenuTree(_ element: Accessibility.Element, indent: Int) throws {
            let prefix = String(repeating: "  ", count: indent)
            let role = (try? element.attribute(AXAttribute.role)()) ?? ""
            let title = (try? element.attribute(AXAttribute.title)()) ?? ""

            if !title.isEmpty && role != "AXMenu" {
                let enabled = (try? element.attribute(AXAttribute.enabled)()) ?? true
                var line = "\(prefix)\(title)"
                if !enabled {
                    line += " [disabled]"
                }
                print(line)
            }

            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            guard let children = try? childrenAttr() else { return }

            for child in children {
                try showMenuTree(child, indent: indent + 1)
            }
        }

        // MARK: - Search Menus

        private func searchMenus(menuBar: Accessibility.Element, pattern: String) throws {
            print("Searching for '\(pattern)'...")
            print(String(repeating: "-", count: 50))

            var results: [(path: String, title: String, shortcut: String)] = []
            try searchMenuRecursive(menuBar, pattern: pattern.lowercased(), currentPath: "", results: &results)

            if results.isEmpty {
                print("No menu items found matching '\(pattern)'")
            } else {
                print("Found \(results.count) item(s):\n")
                for result in results {
                    var line = result.path
                    if !result.shortcut.isEmpty {
                        line += "  (\(result.shortcut))"
                    }
                    print(line)
                }
            }
        }

        private func searchMenuRecursive(
            _ element: Accessibility.Element,
            pattern: String,
            currentPath: String,
            results: inout [(path: String, title: String, shortcut: String)]
        ) throws {
            let role = (try? element.attribute(AXAttribute.role)()) ?? ""
            let title = (try? element.attribute(AXAttribute.title)()) ?? ""

            let newPath: String
            if title.isEmpty || role == "AXMenuBar" || role == "AXMenu" {
                newPath = currentPath
            } else if currentPath.isEmpty {
                newPath = title
            } else {
                newPath = "\(currentPath) > \(title)"
            }

            // Check if this item matches
            if !title.isEmpty && title.lowercased().contains(pattern) {
                let shortcutAttr: Accessibility.Attribute<String> = element.attribute(.init("AXMenuItemCmdChar"))
                let shortcut = (try? shortcutAttr()) ?? ""
                let modifiersAttr: Accessibility.Attribute<Int> = element.attribute(.init("AXMenuItemCmdModifiers"))
                let modifiers = (try? modifiersAttr()) ?? 0
                let fullShortcut = shortcut.isEmpty ? "" : "\(formatModifiers(modifiers))\(shortcut)"
                results.append((path: newPath, title: title, shortcut: fullShortcut))
            }

            // Recurse into children
            let childrenAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXChildren"))
            guard let children = try? childrenAttr() else { return }

            for child in children {
                try searchMenuRecursive(child, pattern: pattern, currentPath: newPath, results: &results)
            }
        }

        // MARK: - Helpers

        private func formatModifiers(_ modifiers: Int) -> String {
            var result = ""
            // macOS modifier flags: 1=Shift, 2=Option, 4=Control, 8=Command (but stored inversely in some cases)
            // Actually the AXMenuItemCmdModifiers uses different encoding
            // 0 = Command only, 1 = Command+Shift, 2 = Command+Option, etc.

            // Simplified: just show ⌘ for now since most shortcuts use Command
            if modifiers == 0 {
                result = "⌘"
            } else if modifiers & 1 != 0 {
                result = "⌘⇧"
            } else if modifiers & 2 != 0 {
                result = "⌘⌥"
            } else if modifiers & 4 != 0 {
                result = "⌘⌃"
            } else {
                result = "⌘"
            }
            return result
        }
    }
}
