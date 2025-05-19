import Foundation
import SwiftServerFoundation
import Logging

private let log = Logger(label: "sws.imdatabase")

public final class FileWatcher {
    private let target: URL
    private var source: DispatchSourceFileSystemObject?
    private static let queue = DispatchQueue(label: "sws.file-watcher")
    private var name: String

    public private(set) var events = Topic<DispatchSource.FileSystemEvent>()

    public init(watching file: URL, name: String? = nil) {
        target = file
        self.name = name ?? file.lastPathComponent
    }

    deinit {
        stopListeningIfNecessary()
    }
}

public extension FileWatcher {
    enum Error: Swift.Error {
        case openingDatabaseFile
    }
}

// MARK: - Public Interface

public extension FileWatcher {
    func beginListening() throws(Error) {
        try setUpSource(withFileDescriptor: openDatabase(), for: .all, on: Self.queue).activate()
    }

    func stopListeningIfNecessary() {
        if let source {
            log.debug("\(name): canceling source")

            source.cancel()
            self.source = nil
        }
    }
}

// MARK: - Source

extension FileWatcher {
    private func openDatabase() throws(Error) -> Int32 {
        stopListeningIfNecessary()

        let fd = open(target.path, O_EVTONLY | O_SYMLINK)
        log.debug("\(name): opened target: fd=\(fd)")
        guard fd > 0 else {
            throw .openingDatabaseFile
        }

        return fd
    }

    @discardableResult
    private func setUpSource(withFileDescriptor fd: Int32, for events: DispatchSource.FileSystemEvent, on queue: DispatchQueue) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)

        log.debug("\(name): created fs object source: \(source.description)")

        source.setEventHandler { [weak self] in
            self?.events.broadcast(source.data)
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }

            let status = close(fd)
            if status != 0 {
                log.error("\(name): couldn't close database: fd=\(fd), status=\(status)")
            }
        }

        self.source = source
        return source
    }
}
