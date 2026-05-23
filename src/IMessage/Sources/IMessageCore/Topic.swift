import Foundation

public final class Topic<T> {
    public typealias BufferingPolicy = AsyncStream<T>.Continuation.BufferingPolicy

    private let bufferingPolicy: BufferingPolicy
    private var subscriptions = Protected<[UUID: AsyncStream<T>.Continuation]>([:])

    public init(bufferingPolicy: BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }
}

extension Topic: @unchecked Sendable {}

public extension Topic {
    func broadcast(_ value: sending T) {
        let currentSubscriptions = subscriptions.withLock {
            Array($0.values)
        }
        for subscription in currentSubscriptions {
            subscription.yield(value)
        }
    }

    func subscribe() -> AsyncStream<T> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: T.self, bufferingPolicy: bufferingPolicy)
        cont.onTermination = { [weak self] _ in
            self?.subscriptions.withLock {
                $0[id] = nil
            }
        }
        subscriptions.withLock {
            $0[id] = cont
        }

        return stream
    }

    package var subscriptionCount: Int {
        subscriptions.withLock { $0.count }
    }

    /**
     * Finishes all current subscribers and empties the subscriptions list.
     *
     * New subscribers may still be registered after calling this method.
     */
    func finishCurrentSubscribers() {
        let currentSubscriptions = subscriptions.withLock {
            let current = Array($0.values)
            $0.removeAll()
            return current
        }
        for subscription in currentSubscriptions {
            subscription.finish()
        }
    }
}
