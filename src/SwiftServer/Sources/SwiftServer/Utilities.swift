import Foundation

struct ErrorMessage: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        Logger.log(description)
        self.description = description
    }
}

extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        if let wrapped = self {
            return wrapped
        } else {
            throw error()
        }
    }
}

// will be optimized out in release mode
@_transparent
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard Preferences.isLoggingEnabled else { return }
    print(message())
    #endif
}

func retry<T>(
    withTimeout timeout: TimeInterval,
    interval: TimeInterval? = nil,
    _ perform: () throws -> T,
    onError: ((_ attempt: Int, _ err: Error?) throws -> Void)? = nil
) throws -> T {
    let start = Date()
    var res: Result<T, Error>
    var attempt = 0
    repeat {
        res = Result(catching: perform)
        switch res {
        case let .success(val):
            return val
        case let .failure(err):
            do {
                try onError?(attempt, err)
                attempt += 1
            } catch {
                debugLog("retry onError errored \(error)")
            }
        }
        interval.map(Thread.sleep(forTimeInterval:))
    } while -start.timeIntervalSinceNow < timeout
    return try res.get()
}

func runOnMainThread<T>(fn: () throws -> T) rethrows -> T {
    debugLog("runOnMainThread: Thread.isMainThread=\(Thread.isMainThread) queueName=\(__dispatch_queue_get_label(nil))")
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
