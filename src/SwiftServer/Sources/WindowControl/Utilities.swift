import Foundation

class Box<T> {
    var value: T
    init(_ value: T) {
        self.value = value
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
