import Foundation

public struct TimeoutError: Error, Equatable, Sendable {}

func withTimeout<Success>(
    _ timeout: TimeInterval,
    operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    let deadline: Date = Date().addingTimeInterval(timeout)

    guard timeout > 0 else {
        throw TimeoutError()
    }

    let timeoutTask: @Sendable () async throws -> Success = {
        let remainingTime = deadline.timeIntervalSinceNow

        guard remainingTime > 0 else {
            throw TimeoutError()
        }

        if #available(macOS 13.0, *) {
            let clock: ContinuousClock = ContinuousClock()
            let deadlineInstant: ContinuousClock.Instant = clock.now.advanced(by: .seconds(remainingTime))
            try await Task.sleep(until: deadlineInstant, tolerance: nil, clock: clock)
        } else {
            try await Task.sleep(forTimeInterval: remainingTime)
        }

        throw TimeoutError()
    }

    return try await withThrowingTaskGroup(of: Success.self) { group in
        defer {
            group.cancelAll()
        }

        if #available(macOS 26.0, *) {
            group.addImmediateTask(operation: timeoutTask)
        } else {
            group.addTask(operation: timeoutTask)
        }

        group.addTask {
            try await operation()
        }

        guard let value = try await group.next() else {
            throw Swift.CancellationError()
        }

        return value
    }
}

public extension Task where Failure == any Error {
    init(
        name: String? = nil,
        timeout: TimeInterval,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) {
        self.init(name: name, priority: priority) {
            try await withTimeout(timeout, operation: operation)
        }
    }
}
