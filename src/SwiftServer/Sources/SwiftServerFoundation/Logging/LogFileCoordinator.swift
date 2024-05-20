import Foundation

/// Coordinates writes to a log file to prevent racing.
// TODO(skip): kabir says: a channel-style AsyncSequence could be faster
actor LogFileCoordinator {
    static let shared = LogFileCoordinator()

    static private let fileSizeLimit = 100_000_000

    private let handle: FileHandle
    private init?(url: URL? = Log.file) {
        guard let url else { return nil }

        guard let handle = (try? FileHandle(forWritingTo: url)) ?? ({
            try? "".write(to: url, atomically: false, encoding: .utf8)
            return try? FileHandle(forWritingTo: url)
        })() else {
            return nil
        }

        self.handle = handle
        self.handle.seekToEndOfFile()

        if self.handle.offsetInFile > Self.fileSizeLimit {
            try? self.handle.truncate(atOffset: 0)
        }
    }

    func emit(line: String) {
        handle.write(Data("\(line)\n".utf8))
    }

    deinit { try? handle.close() }
}
