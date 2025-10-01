import Foundation
import Logging
import SwiftServerFoundation

private let log = Logger(label: "watcher")

public final class FileWatcher {
    /** The file being monitored. */
    private let targetFile: URL

    private var source: DispatchSourceFileSystemObject?
    private static let queue = DispatchQueue(label: "sws.file-watcher")
    private var name: String
    private var fd: FileDescriptor?

    public typealias Callback = @Sendable (FileWatcher, sending DispatchSource.FileSystemEvent) -> Void
    public var callback: Callback

    public init(watching file: URL, name: String? = nil, onEvent callback: @escaping Callback) {
        self.targetFile = file
        self.name = name ?? file.lastPathComponent
        self.callback = callback
    }

    deinit {
        stopListeningIfNecessary()
    }
}

// MARK: - Public Interface

public extension FileWatcher {
    func beginListening() throws(Error) {
        stopListeningIfNecessary()

        try setUpSource(for: .all, on: Self.queue)
    }

    func stopListeningIfNecessary() {
        if let source {
            log.debug("\(name): canceling source")

            source.cancel()
            self.source = nil
        }
    }

    // used to detect when the file being monitored is unlinked; if it has no
    // hard links, then it's probably been deleted.
    func hasHardLinks() throws(Error) -> Bool? {
        guard let fd else { return nil }
        return try fd.hasHardLinks()
    }
}

// MARK: - Source

extension FileWatcher {
    @discardableResult
    private func setUpSource(for events: DispatchSource.FileSystemEvent, on queue: DispatchQueue) throws(Error) -> any DispatchSourceFileSystemObject {
        stopListeningIfNecessary()

        let fd = try FileDescriptor(path: targetFile.path, flags: O_EVTONLY | O_SYMLINK)
        self.fd = fd
        log.debug("\(name): opened target: fd=\(fd.guts)")

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd.guts, eventMask: events, queue: queue)
        log.debug("\(name): created fs object source: \(source.description)")

        source.setEventHandler { [weak self] in
            guard let self else {
                log.warning("event: no self?")
                return
            }

            callback(self, source.data)
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                log.warning("cancel: no self?")
                return
            }

            do {
                try fd.close()
            } catch {
                log.error("\(name): cancel: couldn't close fd: fd=\(fd.guts), error=\(error)")
            }
            log.warning("\(name): cancel: closed fd: fd=\(fd.guts)")
        }

        self.source = source
        source.activate()
        return source
    }
}

// MARK: - Error

public extension FileWatcher {
    enum Error: Swift.Error, CustomStringConvertible {
        // NOTE: reading `errno` is technically wonky in Swift because malloc can change it, and
        // Swift doesn't provide guarantees around this - an invisible allocation
        // might clobber the value. but it's probably fine
        case open(errno: Int32)
        case fstat(errno: Int32)
        case close(errno: Int32)

        public var description: String {
            switch self {
            case let .open(errno):
                "open: \(errno.errnoDescription)"
            case let .fstat(errno):
                "fstat: \(errno.errnoDescription)"
            case let .close(errno):
                "close: \(errno.errnoDescription)"
            }
        }
    }
}

private extension Int32 {
    var errnoDescription: String {
        String(cString: strerror(self))
    }
}

// MARK: - FileDescriptor

// this should really be `~Copyable` with `close` being `consuming`, but this is
// hard to effectively consume from within escaping closures (necessary with
// `DispatchSource`?)
private struct FileDescriptor {
    let guts: Int32

    init(path: String, flags: Int32) throws(FileWatcher.Error) {
        let fd = Darwin.open(path, flags)
        guard fd > 0 else {
            throw .open(errno: errno)
        }
        self.guts = fd
    }

    func numberOfHardLinks() throws(FileWatcher.Error) -> Int {
        var st = stat()
        guard fstat(guts, &st) == 0 else {
            throw .fstat(errno: errno)
        }
        return Int(st.st_nlink)
    }

    func close() throws(FileWatcher.Error) {
        guard Darwin.close(guts) == 0 else {
            throw .close(errno: errno)
        }
    }
}

extension FileDescriptor {
    func hasHardLinks() throws(FileWatcher.Error) -> Bool {
        try numberOfHardLinks() > 0
    }
}
