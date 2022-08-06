import Foundation

enum Logger {
    static var logFile: URL? {
        guard let libraryDirectory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        return libraryDirectory
            .appendingPathComponent("jack", isDirectory: true)
            .appendingPathComponent("platform-imessage.log")
    }

    static func log(_ message: String) {
        guard Preferences.isLoggingEnabled else { return }
        guard let logFile = logFile else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = formatter.string(from: Date())
        let str = "\(timestamp): \(message)"
        print(str)
        guard let data = "\(str)\n".data(using: String.Encoding.utf8) else { return }

        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFile, options: .atomicWrite)
        }
    }
}
