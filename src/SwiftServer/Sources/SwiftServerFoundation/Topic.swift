public final class Topic<T> {
    public typealias BufferingPolicy = AsyncStream<T>.Continuation.BufferingPolicy

    private let bufferingPolicy: BufferingPolicy
    // TODO(skip): this should really be using a `Mutex<T>`-like type
    private var subscriptions = [AsyncStream<T>.Continuation]()
    private var lock = UnfairLock()

    public init(bufferingPolicy: BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }
}

extension Topic: @unchecked Sendable {}

public extension Topic {
    func broadcast(_ value: sending T) {
        lock.lock {
            for subscription in subscriptions {
                subscription.yield(value)
            }
        }
    }

    func subscribe() -> AsyncStream<T> {
        let (stream, cont) = AsyncStream.makeStream(of: T.self, bufferingPolicy: bufferingPolicy)
        lock.lock {
            subscriptions.append(cont)
        }

        return stream
    }
}
