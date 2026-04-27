import Foundation

/// The Node and CLI surfaces still serialize JSON strings, but PlatformAPI.swift
/// now returns these wrappers internally so page/message/thread output shapes
/// stay explicit until the final bridge boundary.
public protocol PlatformAPIJSONObjectConvertible {
    var jsonObject: JSONObject { get }
}

public struct PlatformAPIThread: PlatformAPIJSONObjectConvertible {
    public let jsonObject: JSONObject

    public init(jsonObject: JSONObject) {
        self.jsonObject = jsonObject
    }
}

public struct PlatformAPIMessage: PlatformAPIJSONObjectConvertible {
    public let jsonObject: JSONObject

    public init(jsonObject: JSONObject) {
        self.jsonObject = jsonObject
    }
}

public struct PlatformAPIPage<Item: PlatformAPIJSONObjectConvertible>: PlatformAPIJSONObjectConvertible {
    public let items: [Item]
    public let hasMore: Bool
    public let oldestCursor: String?

    public init(items: [Item], hasMore: Bool, oldestCursor: String? = nil) {
        self.items = items
        self.hasMore = hasMore
        self.oldestCursor = oldestCursor
    }

    public var jsonObject: JSONObject {
        compactDictionary([
            "items": items.map(\.jsonObject),
            "hasMore": hasMore,
            "oldestCursor": oldestCursor,
        ])
    }
}
