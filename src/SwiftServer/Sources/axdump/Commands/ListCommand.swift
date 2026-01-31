import Foundation
import ArgumentParser
import AccessibilityControl
import AppKit

extension AXDump {
    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "List running applications with accessibility elements",
            discussion: """
                Lists all running applications that can be inspected via accessibility APIs.
                By default, only shows regular (foreground) applications.

                EXAMPLES:
                  axdump list              List foreground apps with PIDs
                  axdump list -a           Include background/menu bar apps
                  axdump list -v           Show window count and app title
                  axdump list -av          Verbose listing of all apps
                  axdump list --list-roles Show all known accessibility roles
                """
        )

        @Flag(name: .shortAndLong, help: "Show all applications (including background)")
        var all: Bool = false

        @Flag(name: .shortAndLong, help: "Show detailed information")
        var verbose: Bool = false

        @Flag(name: .long, help: "List all known accessibility roles")
        var listRoles: Bool = false

        @Flag(name: .long, help: "List all known accessibility subroles")
        var listSubroles: Bool = false

        @Flag(name: .long, help: "List all known accessibility actions")
        var listActions: Bool = false

        func run() throws {
            // Handle reference listings
            if listRoles {
                print(AXRoles.fullHelpText())
                return
            }
            if listSubroles {
                print(AXSubroles.fullHelpText())
                return
            }
            if listActions {
                print(AXActions.fullHelpText())
                return
            }

            guard Accessibility.isTrusted(shouldPrompt: true) else {
                print("Error: Accessibility permissions required")
                print("Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility")
                throw ExitCode.failure
            }

            let apps = NSWorkspace.shared.runningApplications
            let filteredApps = all ? apps : apps.filter { $0.activationPolicy == .regular }

            let sortedApps = filteredApps.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

            print("Running Applications:")
            print(String(repeating: "-", count: 60))

            for app in sortedApps {
                let name = app.localizedName ?? "Unknown"
                let pid = app.processIdentifier
                let bundleID = app.bundleIdentifier ?? "N/A"

                if verbose {
                    print("\(String(format: "%6d", pid))  \(name)")
                    print("        Bundle: \(bundleID)")

                    let element = Accessibility.Element(pid: pid)
                    let windowsAttr: Accessibility.Attribute<[Accessibility.Element]> = element.attribute(.init("AXWindows"))
                    if let windowCount = try? windowsAttr.count() {
                        print("        Windows: \(windowCount)")
                    }
                    if let title: String = try? element.attribute(.init("AXTitle"))() {
                        print("        Title: \(title)")
                    }
                    print()
                } else {
                    print("\(String(format: "%6d", pid))  \(name) (\(bundleID))")
                }
            }
        }
    }
}
