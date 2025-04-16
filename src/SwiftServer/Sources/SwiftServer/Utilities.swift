import Foundation
import SwiftServerFoundation

func runOnMainThread<T>(fn: () throws -> T) rethrows -> T {
    Log.default.debug("runOnMainThread: Thread.isMainThread=\(Thread.isMainThread) queueName=\(__dispatch_queue_get_label(nil))")
    if Thread.isMainThread {
        return try fn()
    } else {
        return try DispatchQueue.main.sync {
            try fn()
        }
    }
}

func debounced(for timeInterval: TimeInterval, action: @escaping (() -> Void)) -> (() -> Void) {
    var timer: Timer?
    return {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { _ in
            action()
        }
    }
}

// iMessage;-;hi@kishan.info → hi@kishan.info
@inlinable func threadIDToAddress(_ threadID: String) -> String? {
    splitThreadID(threadID)?.2
}

// iMessage;-;hi@kishan.info → ("iMessage", "-", "hi@kishan.info")
@inlinable func splitThreadID(_ threadID: String) -> (String.SubSequence, String.SubSequence, String)? {
    let components = threadID.split(separator: ";", maxSplits: 2)
    guard components.count == 3 else { return nil }
    return (components[0], components[1], String(components[2]))
}

func containsLink(_ text: String) -> Bool {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
    return matches?.count ?? 0 > 0
}

func jsonStringify<T: Encodable>(_ input: T) throws -> String {
    let data = try encoder.encode(input)
    return String(decoding: data, as: UTF8.self)
}

private let encoder = JSONEncoder()

struct System {
    /// "Darwin"
    let os: String
    /// e.g. "hostname.local"
    let node: String
    /// e.g. "24.3.0" (XNU version)
    let kernelVersion: String
    /// e.g. "Darwin Kernel Version 24.3.0: …"
    let kernelRelease: String
    /// e.g. "arm64"
    let architecture: String
    /// e.g. "Version 15.3.2 (Build 24D81)"
    let osVersion: String

    init?() {
        var info = utsname()
        guard uname(&info) == 0 else {
            return nil
        }

        func read<C>(_ keyPath: KeyPath<utsname, C>) -> String {
            withUnsafePointer(to: info[keyPath: keyPath]) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
            }
        }

        os = read(\.sysname)
        node = read(\.nodename)
        kernelVersion = read(\.release)
        kernelRelease = read(\.version)
        architecture = read(\.machine)
        osVersion = ProcessInfo().operatingSystemVersionString
    }
}

