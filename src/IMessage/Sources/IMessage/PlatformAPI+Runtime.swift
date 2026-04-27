import Foundation

extension PlatformAPI {
    public typealias Event = [String: Any]
    public typealias EventSender = @Sendable ([Event]) throws -> Void

    public final class CallbackQueue: Sendable {
        private let runOnQueue: @Sendable (@escaping @Sendable () throws -> Void) throws -> Void

        public init(_ runOnQueue: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> Void) {
            self.runOnQueue = runOnQueue
        }

        public func run(_ action: @escaping @Sendable () throws -> Void) throws {
            try runOnQueue(action)
        }
    }

    public final class CleanupHook: Sendable {
        private let _remove: @Sendable () async throws -> Void

        public init(remove: @escaping @Sendable () async throws -> Void) {
            self._remove = remove
        }

        public func remove() async throws {
            try await _remove()
        }
    }

    public struct Runtime: Sendable {
        public var makeCallbackQueue: @Sendable (_ label: String) async throws -> CallbackQueue
        public var reportMessageToSentry: @Sendable (_ message: String) throws -> Void
        public var addCleanupHook: @Sendable (_ action: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws -> CleanupHook

        public init(
            makeCallbackQueue: @escaping @Sendable (_ label: String) async throws -> CallbackQueue,
            reportMessageToSentry: @escaping @Sendable (_ message: String) throws -> Void,
            addCleanupHook: @escaping @Sendable (_ action: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void) async throws -> CleanupHook
        ) {
            self.makeCallbackQueue = makeCallbackQueue
            self.reportMessageToSentry = reportMessageToSentry
            self.addCleanupHook = addCleanupHook
        }

        public static let noop = Runtime(
            makeCallbackQueue: { _ in
                CallbackQueue { action in
                    try action()
                }
            },
            reportMessageToSentry: { _ in },
            addCleanupHook: { _ in
                CleanupHook(remove: {})
            }
        )
    }

    public enum AssetResult: Sendable {
        case url(String)
        case data(Data)
    }
}
