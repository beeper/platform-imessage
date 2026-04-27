import Foundation

public typealias PlatformEvent = [String: Any]
public typealias PlatformEventSender = @Sendable ([PlatformEvent]) throws -> Void

public final class PlatformCallbackQueue: Sendable {
    private let runOnQueue: @Sendable (@escaping @Sendable () throws -> Void) throws -> Void

    public init(_ runOnQueue: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> Void) {
        self.runOnQueue = runOnQueue
    }

    public func run(_ action: @escaping @Sendable () throws -> Void) throws {
        try runOnQueue(action)
    }
}

public final class PlatformCleanupHook: Sendable {
    private let _remove: @Sendable () async throws -> Void

    public init(remove: @escaping @Sendable () async throws -> Void) {
        self._remove = remove
    }

    public func remove() async throws {
        try await _remove()
    }
}

public struct PlatformAPIRuntime: Sendable {
    public var makeCallbackQueue: @Sendable (_ label: String) async throws -> PlatformCallbackQueue
    public var reportMessageToSentry: @Sendable (_ message: String) throws -> Void
    public var addCleanupHook: @Sendable (_ action: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws -> PlatformCleanupHook

    public init(
        makeCallbackQueue: @escaping @Sendable (_ label: String) async throws -> PlatformCallbackQueue,
        reportMessageToSentry: @escaping @Sendable (_ message: String) throws -> Void,
        addCleanupHook: @escaping @Sendable (_ action: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws -> PlatformCleanupHook
    ) {
        self.makeCallbackQueue = makeCallbackQueue
        self.reportMessageToSentry = reportMessageToSentry
        self.addCleanupHook = addCleanupHook
    }

    public static let noop = PlatformAPIRuntime(
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

public enum PlatformAssetResult: Sendable {
    case url(String)
    case data(Data)
}
