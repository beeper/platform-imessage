import Foundation

typealias PlatformEvent = [String: Any]
typealias PlatformEventSender = @Sendable ([PlatformEvent]) throws -> Void

final class PlatformCallbackQueue: Sendable {
    private let runOnQueue: @Sendable (@escaping @Sendable () throws -> Void) throws -> Void

    init(_ runOnQueue: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> Void) {
        self.runOnQueue = runOnQueue
    }

    func run(_ action: @escaping @Sendable () throws -> Void) throws {
        try runOnQueue(action)
    }
}

final class PlatformCleanupHook: Sendable {
    private let _remove: @Sendable () async throws -> Void

    init(remove: @escaping @Sendable () async throws -> Void) {
        self._remove = remove
    }

    func remove() async throws {
        try await _remove()
    }
}

struct PlatformAPIRuntime: Sendable {
    var makeCallbackQueue: @Sendable (_ label: String) async throws -> PlatformCallbackQueue
    var reportMessageToSentry: @Sendable (_ message: String) throws -> Void
    var addCleanupHook: @Sendable (_ action: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws -> PlatformCleanupHook

    static let noop = PlatformAPIRuntime(
        makeCallbackQueue: { _ in
            PlatformCallbackQueue { action in
                try action()
            }
        },
        reportMessageToSentry: { _ in },
        addCleanupHook: { _ in
            PlatformCleanupHook(remove: {})
        }
    )
}

enum PlatformAssetResult: Sendable {
    case url(String)
    case data(Data)
}
