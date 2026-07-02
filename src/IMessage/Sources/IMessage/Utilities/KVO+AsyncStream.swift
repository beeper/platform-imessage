import Foundation

public extension AsyncSequence {
    func first(
        until deadline: Date,
        where predicate: @escaping @Sendable (Element) async throws -> Bool
    ) async throws -> Element? where Element: Sendable {
        guard Date() < deadline else {
            return nil
        }

        let timeoutTask: @Sendable () async throws -> Element? = {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return nil
            }

            do {
                if #available(macOS 13.0, *) {
                    let clock = ContinuousClock()
                    let clockDeadline = clock.now.advanced(by: .seconds(remaining))
                    try await Task<Never, Never>.sleep(until: clockDeadline, tolerance: nil, clock: clock)
                } else {
                    try await Task.sleep(forTimeInterval: remaining)
                }
            } catch is CancellationError {
                return nil
            }

            return nil
        }

        return try await withThrowingTaskGroup(of: Element?.self) { group in
            if #available(macOS 26.0, *) {
                group.addImmediateTask(operation: timeoutTask)
            } else {
                group.addTask(operation: timeoutTask)
            }

            group.addTask {
                for try await value in self {
                    try Task.checkCancellation()
                    if try await predicate(value) {
                        return value
                    }
                }

                return nil
            }

            defer {
                group.cancelAll()
            }

            return try await group.next() ?? nil
        }
    }
}

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
    func waitForValue<Value: Sendable>(
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

        return nil
    }

    @discardableResult
    func waitForValue<Value: Sendable>(
        _ keyPath: KeyPath<Self, Value>,
        _ expectedValue: Value,
        options: NSKeyValueObservingOptions = [.initial, .new]
    ) async throws -> Value? where Value: Equatable {
        try await self.waitForValue(keyPath) { value in
            return value == expectedValue
        }
    }

    @discardableResult
    func waitForValue<Value: Sendable>(
        _ keyPath: KeyPath<Self, Value>,
        timeout: TimeInterval,
        options: NSKeyValueObservingOptions = [.initial, .new],
        where predicate: @escaping @Sendable (Value) async throws -> Bool
    ) async throws -> Value {
        try await Task.withTimeout(timeout) { [self] in
            guard let value = try await self.waitForValue(keyPath, options: options, where: predicate) else {
                throw Swift.CancellationError()
            }

            return value
        }
    }
}
