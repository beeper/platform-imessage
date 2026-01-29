import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit
import CoreGraphics

// MARK: - Main Command

@main
struct AXDump: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "axdump",
        abstract: "Dump accessibility tree information for running applications",
        discussion: """
            A command-line tool for exploring and debugging macOS accessibility trees.
            Requires accessibility permissions (System Preferences > Security & Privacy > Privacy > Accessibility).

            QUICK START:
              axdump watch                      Live explore elements under cursor
              axdump find 710 "Save" --click    Find and click "Save" button
              axdump find 710 --role TextField --type "hello"
              axdump menu 710 "File > Save" -x  Execute menu item

            EXAMPLES:
              axdump list                       List running applications with PIDs
              axdump find 710 "OK" -c           Find "OK" button and click it
              axdump find 710 --role Button     Find all buttons
              axdump watch 710 --path           Watch with element paths
              axdump dump 710 -d 2              Dump tree (2 levels deep)
              axdump menu 710 -m "Edit" -x      Explore Edit menu
              axdump key 710 "cmd+c"            Send keyboard shortcut

            WORKFLOW:
              1. Use 'watch' to explore UI and find elements interactively
              2. Use 'find' to locate and act on elements by text/role
              3. Use 'menu' to explore and execute menu items
              4. Use 'dump' for detailed tree exploration
              5. Use 'key' for keyboard shortcuts

            REFERENCE:
              axdump list --list-roles          Show all known accessibility roles
              axdump list --list-subroles       Show all known subroles
              axdump list --list-actions        Show all known actions

            For more help on a specific command:
              axdump <command> --help
            """,
        subcommands: [
            List.self,
            Find.self,
            Watch.self,
            Dump.self,
            Hierarchy.self,
            Query.self,
            Inspect.self,
            Observe.self,
            // Screenshot and Compare require WindowControl which is not exported from BetterSwiftAX
            // Screenshot.self,
            // Compare.self,
            Action.self,
            Set.self,
            Key.self,
            Menu.self,
        ],
        defaultSubcommand: List.self
    )
}

