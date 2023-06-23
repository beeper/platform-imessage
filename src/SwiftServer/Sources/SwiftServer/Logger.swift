import Foundation

enum Logger {
    static var logFile: URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
            .appendingPathComponent("jack", isDirectory: true)
            .appendingPathComponent("platform-imessage.log")
    }

    static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        return formatter
    }

    static func log(_ message: String) {
        guard Preferences.isLoggingEnabled else { return }
        guard let logFile else { return }

        let timestamp = formatter.string(from: Date())
        let str = "\(timestamp): \(message)"
        print(str)
        guard let data = "\(str)\n".data(using: String.Encoding.utf8) else { return }

        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                defer { fileHandle.closeFile() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            }
        } else {
            try? data.write(to: logFile, options: .atomicWrite)
        }
    }
}
