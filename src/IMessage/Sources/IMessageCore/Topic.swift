import Combine

public final class Topic<T> {
    private let subject = Protected(PassthroughSubject<T, Never>())

    public init() {}
}

extension Topic: @unchecked Sendable {}

public extension Topic {
    var publisher: AnyPublisher<T, Never> {
        subject.read().eraseToAnyPublisher()
    }

    @discardableResult
    func subscribe(_ receiveValue: @escaping (T) -> Void) -> AnyCancellable {
        publisher.sink(receiveValue: receiveValue)
    }

    func broadcast(_ value: T) {
        subject.read().send(value)
    }

    /**
     * Finishes all current subscribers and empties the subscriptions list.
     *
     * New subscribers may still be registered after calling this method.
     */
    func finishCurrentSubscribers() {
        let previousSubject = subject.withLock { currentSubject in
            let previousSubject = currentSubject
            currentSubject = PassthroughSubject<T, Never>()
            return previousSubject
        }
        previousSubject.send(completion: .finished)
    }
}
