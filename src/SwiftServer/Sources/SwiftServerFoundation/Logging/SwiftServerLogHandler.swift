import Logging
import Foundation
import os

private var dateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    formatter.timeZone = TimeZone(abbreviation: "UTC")
    return formatter
}

public typealias SwiftLogger = Logging.Logger

private let osLog = os.OSLog(subsystem: "com.kishanbagaria.jack", category: "swift-server")

public struct SwiftServerLogHandler: LogHandler {
    var identifier: String
    public var logLevel: SwiftLogger.Level = .debug
    public var metadata: SwiftLogger.Metadata = [:]

    public init(identifier: String, logLevel: SwiftLogger.Level = .debug, metadata: SwiftLogger.Metadata = [:]) {
        self.identifier = identifier
        self.logLevel = logLevel
        self.metadata = metadata
    }

    public func log(
        level: SwiftLogger.Level,
        message: SwiftLogger.Message,
        metadata: SwiftLogger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = dateFormatter.string(from: Date())

        let formattedMessage = "\(timestamp) [\(level):\(identifier)] \(message)"
        print(formattedMessage)

        emitToFile(line: formattedMessage)
        emitToOSLog(swiftLogLevel: level, message: formattedMessage)
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
