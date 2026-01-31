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

    public static var logsDirectory: URL? = {
        let applicationSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let profile = ProcessInfo.processInfo.environment["BEEPER_PROFILE"]
        let appDirectoryName = profile.map { "BeeperTexts-\($0)" } ?? "BeeperTexts"
        return applicationSupport?.appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }()

    public static var file: URL? = {
        logsDirectory?.appendingPathComponent("platform-imessage.log")
    }()

    public static var axDumpsDirectory: URL? = {
        logsDirectory?.appendingPathComponent("ax-dumps", isDirectory: true)
    }()

    /// Writes an AX dump to a file and returns the filename.
    /// - Parameters:
    ///   - content: The AX dump content (XML string)
    ///   - prefix: A prefix for the filename (e.g., "app-tree", "focused-element")
    /// - Returns: The filename of the written file, or nil if writing failed
    public static func writeAXDump(_ content: String, prefix: String = "ax-dump") -> String? {
        guard let axDumpsDirectory else {
            debugLog("unable to determine ax-dumps directory")
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: axDumpsDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("failed to create ax-dumps directory: \(error)")
            return nil
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = dateFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-") // colons not allowed in filenames
        let filename = "\(prefix)-\(timestamp).xml"
        let fileURL = axDumpsDirectory.appendingPathComponent(filename)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return filename
        } catch {
            debugLog("failed to write AX dump to file: \(error)")
            return nil
        }
    }

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
