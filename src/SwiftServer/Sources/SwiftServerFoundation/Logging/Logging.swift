import Logging
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
        return applicationSupport?.appendingPathComponent("jack", isDirectory: true).appendingPathComponent("platform-imessage.log")
    }()
}

private let debugLogLogger = Logger(swiftServerLabel: nil)

public func debugLog(_ message: @autoclosure () -> String) {
    debugLogLogger.debug("\(message())")
}
