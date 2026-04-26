import Foundation

enum DetachedWork {
    static func run<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority) {
            try action()
        }.value
    }
}
