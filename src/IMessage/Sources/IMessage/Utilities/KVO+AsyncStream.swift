import Foundation

public extension NSObjectProtocol where Self: NSObject {
    func asyncValues<Value>(
        for keyPath: KeyPath<Self, Value>,
        options: NSKeyValueObservingOptions = [.initial, .new],
        bufferingPolicy: AsyncStream<Value>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<Value> {
        AsyncStream(Value.self, bufferingPolicy: bufferingPolicy) { continuation in
            let observation = self.observe(keyPath, options: options) { _, change in
                guard let value = change.newValue else {
                    return
                }

                continuation.yield(value)
            }

            continuation.onTermination = { _ in
                observation.invalidate()
            }
        }
    }

    @discardableResult
    func waitForValue<Value>(
        _ keyPath: KeyPath<Self, Value>,
        options: NSKeyValueObservingOptions = [.initial, .new],
        where predicate: @escaping @Sendable (Value) async throws -> Bool
    ) async throws -> Value? {
        for await value in asyncValues(for: keyPath, options: options) {
            try Task.checkCancellation()
            if try await predicate(value) {
                return value
            }
        }

        // AsyncStream ends iteration on cancellation without throwing.
        try Task.checkCancellation()
        return nil
    }

    @discardableResult
    func waitForValue<Value>(
        _ keyPath: KeyPath<Self, Value>,
        _ expectedValue: Value,
        options: NSKeyValueObservingOptions = [.initial, .new]
    ) async throws -> Value? where Value: Equatable {
        try await waitForValue(keyPath, options: options) { $0 == expectedValue }
    }

}
