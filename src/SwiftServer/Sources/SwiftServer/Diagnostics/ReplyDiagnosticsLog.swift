import Logging
import Foundation
import SwiftServerFoundation

private let replyDiagnosticsFileCoordinator: LogFileCoordinator? = Log.replyDiagnosticsFile.flatMap { try? LogFileCoordinator(url: $0) }

struct ReplyDiagnosticsLogHandler: LogHandler {
    private var mainHandler: SwiftServerLogHandler
    var logLevel: Logger.Level {
        get { mainHandler.logLevel }
        set { mainHandler.logLevel = newValue }
    }
    var metadata: Logger.Metadata {
        get { mainHandler.metadata }
        set { mainHandler.metadata = newValue }
    }

    init(identifier: String) {
        mainHandler = SwiftServerLogHandler(identifier: identifier)
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // emit to main log (console + main log file + os_log)
        mainHandler.log(level: level, message: message, metadata: metadata, source: source, file: file, function: function, line: line)

        // also emit to the dedicated reply diagnostics file
        let timestamp = sharedLogDateFormatter.string(from: Date())
        let formattedMessage = "\(timestamp) [\(level):reply-diag] \(message)"
        Task { await replyDiagnosticsFileCoordinator?.emit(line: formattedMessage) }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { mainHandler[metadataKey: key] }
        set { mainHandler[metadataKey: key] = newValue }
    }
}
