import Logging
import Foundation
import os

private var dateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    formatter.timeZone = TimeZone(abbreviation: "UTC")
    return formatter
}

public typealias SwiftLogger = Logging.Logger

private let osLog = os.OSLog(subsystem: "com.automattic.beeper.desktop", category: "imessage")

public struct IMessageLogHandler: LogHandler {
    var identifier: String
    public var logLevel: SwiftLogger.Level = .info
    public var metadata: SwiftLogger.Metadata = [:]

    public init(identifier: String, logLevel: SwiftLogger.Level = .info, metadata: SwiftLogger.Metadata = [:]) {
        self.identifier = identifier
        self.logLevel = logLevel
        self.metadata = metadata
    }

    public func log(event: LogEvent) {
        let timestamp = dateFormatter.string(from: Date())

        let formattedMessage = "\(timestamp) [\(event.level):\(identifier)] \(event.message)"
        Log.emitToConsole(formattedMessage)

        emitToFile(line: formattedMessage)
        emitToOSLog(swiftLogLevel: event.level, message: formattedMessage)
    }

    private func emitToOSLog(swiftLogLevel: SwiftLogger.Level, message: String) {
        // `.debug` isn't persisted
        let osLogLevel: OSLogType = switch swiftLogLevel {
        case .critical: .fault
        case .error: .error
        case .warning: .default
        case .notice: .default
        case .info: .default
        case .debug: .debug
        case .trace: .debug
        }

        os_log(osLogLevel, log: osLog, "%{public}s", message)
    }

    private func emitToFile(line: String) {
        Task { await LogFileCoordinator.shared?.emit(line: line) }
    }

    public subscript(metadataKey _: String) -> SwiftLogger.Metadata.Value? {
        get { nil }
        set(newValue) { }
    }
}
