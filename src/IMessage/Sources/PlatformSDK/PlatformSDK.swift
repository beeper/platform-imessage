import Foundation

/// Swift models for the public shapes defined by `@textshq/platform-sdk`
/// https://github.com/TextsHQ/platform-sdk
public enum PlatformSDK {
    public typealias ID = String
    public typealias UserID = ID
    public typealias ThreadID = ID
    public typealias MessageID = ID
    public typealias AttachmentID = ID
    /// `platform-sdk` exposes these as `Date`; across the JSON bridge we emit epoch milliseconds.
    public typealias Timestamp = Int64
}

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct Paginated<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool
    }

    @PlatformSDKJSONObject
    public struct PaginatedWithCursors<Item: JSONObjectConvertible>: JSONObjectConvertible {
        public let items: [Item]
        public let hasMore: Bool
        public let oldestCursor: String?
        public let newestCursor: String?
    }
}

extension PlatformSDK.Paginated: Sendable where Item: Sendable {}
extension PlatformSDK.PaginatedWithCursors: Sendable where Item: Sendable {}
