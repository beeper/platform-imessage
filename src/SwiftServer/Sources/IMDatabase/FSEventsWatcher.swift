import Cocoa
import Foundation
import Logging
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "fsevent")

// FSEvents is better for detecting FS events that occur in a directory tree,
// such as files being created or deleted. it doesn't seem to work well for
// detecting changes to files, such as `chat.db-wal`. use FileWatcher for that.
public final class FSEventsWatcher {
    private var stream: FSEventStreamRef!

    public typealias Callback = @Sendable (FSEventsWatcher, sending FSEventsWatcher.Event) -> Void

    // not thread-safe
    public var callback: Callback

    public init(
        watchingPath path: String,
        includingFiles: Bool = false,
        latency: TimeInterval = 1.0 / 60.0,
        onEvent callback: @escaping Callback,
    ) throws(Error) {
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagMarkSelf
        )
        if includingFiles {
            flags |= numericCast(kFSEventStreamCreateFlagFileEvents)
        }

        self.callback = callback

        // https://www.mikeash.com/pyblog/friday-qa-2017-08-11-swiftunmanaged.html#:~:text=Asynchronous%20Multi%2DShot%20Callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { $0.flatMap(Unmanaged<FSEventsWatcher>.fromOpaque)?.release() },
            copyDescription: nil,
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [path as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags,
        ) else {
            throw .creatingStream
        }

        self.stream = stream
    }

    deinit {
        print("fsevents watcher deinit")
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

public extension FSEventsWatcher {
    /** Starts the event stream. Make sure to set a dispatch queue before calling. */
    func start() throws(Error) {
        guard FSEventStreamStart(stream) else {
            throw .startingStream
        }
    }

    /** Schedules the event stream on a given dispatch queue. Pass `nil` to unschedule. */
    func setDispatchQueue(_ queue: DispatchQueue?) {
        FSEventStreamSetDispatchQueue(stream, queue)
    }

    /** Unschedules the event stream from any dispatch queues upon which it had been scheduled. */
    func invalidate() {
        FSEventStreamInvalidate(stream)
    }

    func stop() {
        FSEventStreamStop(stream)
    }
}

public extension FSEventsWatcher {
    /** Asks the FS Events service to immediately flush any undelivered events that have occurred since the last callback invocation. */
    func flush() {
        FSEventStreamFlushSync(stream)
    }

    func setExclusionPaths(_ paths: [String]) throws(Error) {
        guard FSEventStreamSetExclusionPaths(stream, paths as CFArray) else {
            throw .settingStreamExclusionPaths
        }
    }
}

extension FSEventsWatcher: CustomStringConvertible {
    public var description: String {
        FSEventStreamCopyDescription(stream) as String
    }
}

public extension FSEventsWatcher {
    enum Error: Swift.Error {
        case creatingStream
        case startingStream
        case stoppingStream
        case settingStreamExclusionPaths
    }
}

public extension FSEventsWatcher {
    struct Flags: OptionSet, CustomStringConvertible {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public init(rawValue: FSEventStreamEventFlags) {
            self.init(rawValue: Int(rawValue))
        }

        public static let changeOwner = Self(rawValue: kFSEventStreamEventFlagItemChangeOwner)
        // seems to be passed even for removals?
        public static let created = Self(rawValue: kFSEventStreamEventFlagItemCreated)
        public static let finderInfoModified = Self(rawValue: kFSEventStreamEventFlagItemFinderInfoMod)
        public static let inodeMetaModified = Self(rawValue: kFSEventStreamEventFlagItemInodeMetaMod)
        public static let isDirectory = Self(rawValue: kFSEventStreamEventFlagItemIsDir)
        public static let isFile = Self(rawValue: kFSEventStreamEventFlagItemIsFile)
        public static let isHardlink = Self(rawValue: kFSEventStreamEventFlagItemIsHardlink)
        public static let isLastHardlink = Self(rawValue: kFSEventStreamEventFlagItemIsLastHardlink)
        public static let isSymlink = Self(rawValue: kFSEventStreamEventFlagItemIsSymlink)
        public static let modified = Self(rawValue: kFSEventStreamEventFlagItemModified)
        public static let removed = Self(rawValue: kFSEventStreamEventFlagItemRemoved)
        public static let renamed = Self(rawValue: kFSEventStreamEventFlagItemRenamed)
        public static let xattrModified = Self(rawValue: kFSEventStreamEventFlagItemXattrMod)
        public static let ownEvent = Self(rawValue: kFSEventStreamEventFlagOwnEvent)
        public static let cloned = Self(rawValue: kFSEventStreamEventFlagItemCloned)

        public var description: String {
            var names = [String]()
            for (flag, name) in [
                (Flags.changeOwner, "changeOwner"),
                (.created, "created"),
                (.finderInfoModified, "finderInfoModified"),
                (.inodeMetaModified, "inodeMetaModified"),
                (.isDirectory, "isDirectory"),
                (.isFile, "isFile"),
                (.isHardlink, "isHardlink"),
                (.isLastHardlink, "isLastHardlink"),
                (.isSymlink, "isSymlink"),
                (.modified, "modified"),
                (.removed, "removed"),
                (.renamed, "renamed"),
                (.xattrModified, "xattrModified"),
                (.ownEvent, "ownEvent"),
                (.cloned, "cloned"),
            ] where contains(flag) {
                names.append(name)
            }
            return "<\(names.joined(separator: ", "))>"
        }
    }
}

public extension FSEventsWatcher {
    struct Event: Identifiable {
        public var id: Int
        public var path: String
        public var flags: Flags
    }
}

private func fsEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ callbackInfo: UnsafeMutableRawPointer?,
    _ numberOfEvents: Int,
    _ eventsPaths: UnsafeMutableRawPointer,
    _ eventsFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventsIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let callbackInfo else {
        log.error("fsevent callback: no callback info")
        return
    }

    let wrapper = Unmanaged<FSEventsWatcher>.fromOpaque(callbackInfo).takeUnretainedValue()

    guard let eventsPaths = unsafeBitCast(eventsPaths, to: NSArray.self) as? [String] else {
        log.error("fsevent callback: couldn't cast event paths")
        return
    }
    let eventsFlags = UnsafeBufferPointer(start: eventsFlags, count: numberOfEvents)
    let eventsIDs = UnsafeBufferPointer(start: eventsIDs, count: numberOfEvents)

#if DEBUG
    log.debug("fsevent callback: \(numberOfEvents) event(s)")
#endif
    for (id, (path, flags)) in zip(eventsIDs, zip(eventsPaths, eventsFlags)) {
        let flags = FSEventsWatcher.Flags(rawValue: flags)
        let event = FSEventsWatcher.Event(id: numericCast(id), path: path, flags: flags)
        wrapper.callback(wrapper, event)
    }
}
