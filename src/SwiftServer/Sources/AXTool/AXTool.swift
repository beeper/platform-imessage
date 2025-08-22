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
        subcommands: [Dump.self],
    )

    mutating func run() throws {}
}

extension AXTool {
    struct Dump: ParsableCommand {
        @OptionGroup var options: AXTool.Options

        @Argument(help: "The bundle identifier of the app to target.") var bundleID: String

        mutating func run() throws {
            bootstrap(logLevel: options.logLevel)

            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                Self.exit(withError: ErrorMessage("Found no running applications with the bundle identifier \"\(bundleID)\"."))
            }
            let app = Accessibility.Element(pid: runningApp.processIdentifier)
            print("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>")
            try app.axTool_dump()
        }
    }
}
