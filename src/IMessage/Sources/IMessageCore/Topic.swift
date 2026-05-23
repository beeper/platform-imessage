import Foundation

public final class Topic<T> {
    public typealias BufferingPolicy = AsyncStream<T>.Continuation.BufferingPolicy

    private let bufferingPolicy: BufferingPolicy
    private var subscriptions = Protected<[(id: UUID, continuation: AsyncStream<T>.Continuation)]>([])

    public init(bufferingPolicy: BufferingPolicy = .unbounded) {
        self.bufferingPolicy = bufferingPolicy
    }
}

extension Topic: @unchecked Sendable {}

public extension Topic {
    func broadcast(_ value: sending T) {
        let currentSubscriptions = subscriptions.withLock {
            $0.map(\.continuation)
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
                $0.removeAll { $0.id == id }
            }
        }
        subscriptions.withLock {
            $0.append((id, cont))
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
            let current = $0.map(\.continuation)
            $0.removeAll()
            return current
        }
        for subscription in currentSubscriptions {
            subscription.finish()
        }
    }
}
