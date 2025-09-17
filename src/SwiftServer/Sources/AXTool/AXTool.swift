import AccessibilityControl
import AppKit
import ArgumentParser
import BetterSwiftAXAdditions
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
        subcommands: [Dump.self],
    )

    mutating func run() throws {}
}

extension AXTool {
    struct Dump: ParsableCommand {
        @OptionGroup var options: AXTool.Options

        @Argument(help: "The bundle identifier of the app to target.")
        var bundleID: String
        
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
}
