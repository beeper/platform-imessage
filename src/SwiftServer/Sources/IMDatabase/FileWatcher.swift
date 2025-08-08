import Foundation
import Logging
import SwiftServerFoundation

private let log = Logger(label: "watcher")

public final class FileWatcher {
    private let target: URL
    private var source: DispatchSourceFileSystemObject?
    private static let queue = DispatchQueue(label: "sws.file-watcher")
    private var name: String

    public var noisy = false {
        didSet {
            log.debug("\(name): noisy was set to \(noisy)")
        }
    }
    public private(set) var events = Topic<DispatchSource.FileSystemEvent>()

    public init(watching file: URL, name: String? = nil) {
        self.target = file
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
            guard let self else {
                log.warning("event handler: no self?")
                return
            }

            if noisy {
                log.debug("\(name): noisy: fs object source vended event: fd=\(fd), mask=\(source.mask), data=\(source.data)")
            }

            self.events.broadcast(source.data)
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                log.warning("cancel handler: no self?")
                return
            }

            let status = close(fd)
            guard status == 0 else {
                log.error("\(name): cancel handler: couldn't close database: fd=\(fd), status=\(status)")
                return
            }
            log.warning("\(name): cancel handler: closed database: fd=\(fd)")
        }

        self.source = source
        return source
    }
}
