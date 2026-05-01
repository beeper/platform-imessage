import Foundation

extension PlatformAPI {
    public typealias Event = [String: Any]
    public typealias EventSender = @Sendable ([Event]) throws -> Void

    public struct Runtime: Sendable {
        public var reportMessageToSentry: @Sendable (_ message: String) throws -> Void

        public init(
            reportMessageToSentry: @escaping @Sendable (_ message: String) throws -> Void
        ) {
            self.reportMessageToSentry = reportMessageToSentry
        }

        public static let noop = Runtime(
            reportMessageToSentry: { _ in }
        )
    }

    public enum AssetResult: Sendable {
        case url(String)
        case data(Data)
    }
}
