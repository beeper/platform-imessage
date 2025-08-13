public final class Topic<T> {
    public typealias BufferingPolicy = AsyncStream<T>.Continuation.BufferingPolicy

    private let bufferingPolicy: BufferingPolicy
    private var subscriptions = Protected<[AsyncStream<T>.Continuation]>([])

    public init(bufferingPolicy: BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }
}

extension Topic: @unchecked Sendable {}

public extension Topic {
    func broadcast(_ value: sending T) {
        subscriptions.withLock {
            for subscription in $0 {
                subscription.yield(value)
            }
        }
    }

    func subscribe() -> AsyncStream<T> {
        let (stream, cont) = AsyncStream.makeStream(of: T.self, bufferingPolicy: bufferingPolicy)
        subscriptions.withLock {
            $0.append(cont)
        }

        return stream
    }
}
