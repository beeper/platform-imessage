import AccessibilityControl
import AppKit
import ArgumentParser
import Foundation
import Logging
import SwiftServerFoundation

private func bootstrap(logLevel: Logger.Level = .trace) {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = logLevel
        return handler
    }
}

extension Logger.Level: @retroactive ExpressibleByArgument {}

@main
struct AXTool: ParsableCommand {
    struct Options: ParsableArguments {
        @Option(name: .long, help: "Specify the log level.")
        var logLevel: Logger.Level = .trace
    }

    static let configuration = CommandConfiguration(
        abstract: "Exercise functionality in BetterSwiftAX and friends.",
        subcommands: [Dump.self, MessageCells.self],
    )

    mutating func run() throws {}
}

extension AXTool {
    struct Dump: ParsableCommand {
        @OptionGroup var options: AXTool.Options

        @Argument(help: "The bundle identifier of the app to target.")
        var bundleID = "com.apple.MobileSMS"

        @Flag(name: [.customShort("s"), .customLong("no-sections")], help: "Skips dumping sections.")
        var excludeSections = false
        
        @Flag(name: [.customLong("no-actions")], help: "Skips dumping actions.")
        var excludeActions = false
        
        @Option(name: [.customShort("x"), .customLong("exclude-role")], help: "Skips dumping UI elements with the given role.")
        var excludedRoles = [String]()
        
        @Option(name: [.customShort("a"), .customLong("exclude-attribute")], help: "Skips dumping the named UI element attribute.")
        var excludedAttributes = Array(XMLDumper.defaultExcludedAttributes)
        
        @Option(name: [.customShort("d"), .customLong("max-depth")], help: "Skips dumping elements surpassing the specified depth.")
        var maxDepth: Int? = nil
        
        @Flag(name: [.customShort("p"), .customLong("no-pii")], help: "Attempts to omit PII from the output.")
        var excludingPII = false

        mutating func run() throws {
            bootstrap(logLevel: options.logLevel)

            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                Self.exit(withError: ErrorMessage("Found no running applications with the bundle identifier \"\(bundleID)\"."))
            }
            let app = Accessibility.Element(pid: runningApp.processIdentifier)
            
            var output = ""
            print("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>", to: &output)
            
            try app.dumpXML(
                to: &output,
                maxDepth: maxDepth,
                excludingPII: excludingPII,
                excludingElementsWithRoles: Set(excludedRoles),
                excludingAttributes: Set(excludedAttributes),
                includeActions: !excludeActions,
                includeSections: !excludeSections,
            )
            print(output)
        }
    }

    struct MessageCells: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List transcript children with their localizedDescription, role, identifier, isSelected, childCount, and actions."
        )

        @OptionGroup var options: AXTool.Options

        @Option(name: .long, help: "Max number of transcript children to print.")
        var limit: Int?

        mutating func run() throws {
            bootstrap(logLevel: options.logLevel)

            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
                Self.exit(withError: ErrorMessage("Messages.app is not running."))
            }
            let app = Accessibility.Element(pid: runningApp.processIdentifier)

            // find TranscriptCollectionView
            let tv = try app.recursiveChildren().lazy.first {
                (try? $0.identifier()) == "TranscriptCollectionView"
            }.orThrow(ErrorMessage("TranscriptCollectionView not found"))

            let children = try tv.children()
            let count = limit.map { min($0, children.count) } ?? children.count

            print("TranscriptCollectionView: \(children.count) children (showing \(count))\n")

            for i in 0..<count {
                let child = children[i]
                let role = (try? child.role()) ?? "?"
                let desc = (try? child.localizedDescription()) ?? ""
                let id = (try? child.identifier()) ?? ""
                let childCount = (try? child.children.count()) ?? 0

                print("[\(i)] \(role)\(id.isEmpty ? "" : " id=\"\(id)\"")")
                print("     localizedDescription: \(desc.isEmpty ? "(empty)" : "\"\(desc)\"")")
                print("     childCount: \(childCount)")

                // isSelected on outer element
                do {
                    let sel = try child.isSelected()
                    print("     isSelected (outer): \(sel)")
                } catch {
                    print("     isSelected (outer): ERROR \(error)")
                }

                // inner child details
                if childCount > 0, let inner = try? child.children[0] {
                    let innerRole = (try? inner.role()) ?? "?"
                    let innerId = (try? inner.identifier()) ?? ""
                    let innerDesc = (try? inner.localizedDescription()) ?? ""

                    print("     inner[0]: \(innerRole)\(innerId.isEmpty ? "" : " id=\"\(innerId)\"")")
                    print("       localizedDescription: \(innerDesc.isEmpty ? "(empty)" : "\"\(innerDesc)\"")")

                    do {
                        let sel = try inner.isSelected()
                        print("       isSelected: \(sel)")
                    } catch {
                        print("       isSelected: ERROR \(error)")
                    }

                    // actions on inner child
                    if let actions = try? inner.supportedActions() {
                        let names = actions.map { $0.name.value }
                        print("       actions: \(names)")
                    }
                }

                print()
            }
        }
    }
}
