import Foundation
import ExceptionCatcher

/// Coordinates writes to a log file to prevent racing.
// TODO(skip): kabir says: a channel-style AsyncSequence could be faster
public actor LogFileCoordinator {
    public static let shared = Log.file.flatMap { try? LogFileCoordinator(url: $0) }

    // 5 MiB
    public static let fileSizeLimit = 1_024 * 1_024 * 5

    private var fileURL: URL
    private var lastTrimTime: Date?

    private var handle: FileHandle

    public init(url: URL) throws {
        handle = try Self.handleFor(url)
        fileURL = url

        handle.seekToEndOfFile()
    }

    private static func handleFor(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forUpdating: url)
        } catch {
            // try creating the file first
            try? "".write(to: url, atomically: false, encoding: .utf8)
            return try FileHandle(forUpdating: url)
        }
    }

    func reviveFileHandle() throws {
        print("imsg: reviving file handle")
        handle = try Self.handleFor(fileURL)
    }

    public func emit(line: String) {
        let write = { [handle] in
            try ExceptionCatcher.catch {
                handle.write(Data("\(line)\n".utf8))
            }
        }

        do {
            try write()
        } catch {
            do {
                try reviveFileHandle()
                try write()
            } catch {
                print("imsg: couldn't revive log file handle and retry write: \(error)")
            }
        }

        // wait until twice the file size limit so we aren't constantly trimming
        // after every message
        if handle.offsetInFile > Self.fileSizeLimit * 2 {
            try? tryTrimming(approximatelyPreservingBytesAtEnd: Self.fileSizeLimit)
        }
    }

    deinit {
        try? handle.close()
    }
}

extension LogFileCoordinator {
    private func findClosestPrecedingNewline(bufferLength: Int = 1_024) throws -> Int? {
        var offset = handle.offsetInFile
        let newline = UInt8(ascii: "\n")

        while true {
            guard offset > bufferLength else {
                return nil
            }

            // keep on going backwards
            offset -= UInt64(bufferLength)
            try handle.seek(toOffset: offset)

            let buffer = handle.readData(ofLength: bufferLength)
            if let withinChunk = buffer.firstIndex(of: newline) {
                return withinChunk + Int(offset)
            }
        }
    }

    public func tryTrimming(approximatelyPreservingBytesAtEnd preserved: Int = LogFileCoordinator.fileSizeLimit) throws {
        let newlineDiscoveryBufferLength = 1_024
        handle.seekToEndOfFile()

        let endOffset = Int(handle.offsetInFile)
        guard endOffset > preserved + newlineDiscoveryBufferLength else {
            print("platform-imessage: not trimming, file is only \(endOffset + 1) bytes big")
            return
        }

        if let lastTrimTime, lastTrimTime.timeIntervalSinceNow > -(60 * 5) {
            // guard against frequent trims if those are caused somehow
            return
        }
        defer { lastTrimTime = Date() }

        handle.seek(toFileOffset: UInt64(endOffset - preserved))

        guard let offset = try? findClosestPrecedingNewline() else {
            print("platform-imessage: couldn't find newline while rewinding")
            return
        }

        print("platform-imessage: trimming, found appropriate offset at \(offset)")
        // go to the next line immediately after this newline
        try handle.seek(toOffset: UInt64(offset) + 1)

        // move the tail to the beginning, deleting everything before it
        let tail = handle.readDataToEndOfFile()
        try handle.truncate(atOffset: 0)
        handle.write(tail)

        if tail.last != UInt8(ascii: "\n") {
            handle.write(Data("\n".utf8))
        }

        print("platform-imessage: trimmed, new offset: \(handle.offsetInFile)")
    }
}
