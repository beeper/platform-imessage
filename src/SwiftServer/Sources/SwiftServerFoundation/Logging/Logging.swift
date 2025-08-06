import Logging
import Cocoa
import Foundation

public extension Logger {
    init(swiftServerLabel label: String? = nil) {
        if let label {
            self.init(label: "sws.\(label)")
        } else {
            self.init(label: "sws")
        }
    }

    init(windowControlLabel label: String? = nil) {
        if let label {
            self.init(label: "wc.\(label)")
        } else {
            self.init(label: "wc")
        }
    }
}

public enum Log {
    /// A logger to be used for emitting error messages to the log when
    /// constructing exceptions or other errors.
    public static let errors = Logger(swiftServerLabel: "errors")

    /// A logger for throwaway messages that cannot be delegated to a
    /// more specific logger.
    public static let `default` = Logger(swiftServerLabel: nil)

    public static var file: URL? = {
        let applicationSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let profile = ProcessInfo.processInfo.environment["BEEPER_PROFILE"]
        let appDirectoryName = profile.map { "BeeperTexts-\($0)" } ?? "BeeperTexts"
        return applicationSupport?.appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("platform-imessage.log")
    }()

    public static func purge() throws {
        guard let file else {
            throw ErrorMessage("unable to determine log file URL")
        }
        try FileManager.default.removeItem(at: file)
        // LogFileCoordinator doesn't automatically revive its file handle, unfortunately
        Task {
            do {
                try await LogFileCoordinator.shared?.reviveFileHandle()
            } catch {
                debugLog("couldn't revive log file handle: \(error)")
            }
        }
        debugLog("log file was manually purged")
    }

    public static func reveal() {
        guard let file else {
            fatalError("no log file url?")
        }

        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

private let debugLogLogger = Logger(swiftServerLabel: nil)

public func debugLog(_ message: @autoclosure () -> String) {
    debugLogLogger.debug("\(message())")
}
