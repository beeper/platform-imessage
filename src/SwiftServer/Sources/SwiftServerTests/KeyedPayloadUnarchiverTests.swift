import Foundation
@testable import SwiftServer
import Testing

@Test private func unarchivesKeyedPayloadReferences() throws {
    let archive: JSONObject = [
        "$archiver": "NSKeyedArchiver",
        "$top": ["root": ["CF$UID": 1]],
        "$objects": [
            "$null",
            [
                "$class": ["CF$UID": 5],
                "NS.keys": [["CF$UID": 2], ["CF$UID": 3]],
                "NS.objects": [["CF$UID": 4], ["CF$UID": 0]],
            ],
            "title",
            "empty",
            "Hello",
            [
                "$classes": ["NSDictionary", "NSObject"],
                "$classname": "NSDictionary",
            ],
        ],
    ]

    let payload = try #require(unarchiveKeyedPayload(archive) as? JSONObject)
    let objects = try #require(payload["NS.objects"] as? [Any])
    let klass = try #require(payload["$class"] as? JSONObject)

    #expect(payload["NS.keys"] as? [String] == ["title", "empty"])
    #expect(objects.first as? String == "Hello")
    #expect(objects.last is NSNull)
    #expect(klass["$classes"] as? [String] == ["NSDictionary", "NSObject"])
}

@Test private func unarchivesNumericObjectDictionariesAsOrderedArrays() throws {
    let archive: JSONObject = [
        "$archiver": "NSKeyedArchiver",
        "$top": ["root": ["CF$UID": 1]],
        "$objects": [
            "$null",
            ["NS.objects": ["CF$UID": 2]],
            [
                "2": "third",
                "0": "first",
                "1": "second",
            ],
        ],
    ]

    let payload = try #require(unarchiveKeyedPayload(archive) as? JSONObject)

    #expect(payload["NS.objects"] as? [String] == ["first", "second", "third"])
}

@Test private func unarchivesPropertyListSerializationOutput() throws {
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: ["URL": "https://example.com", "ldtext": "Example"] as NSDictionary,
        requiringSecureCoding: false
    )
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    let payload = try #require(unarchiveKeyedPayload(normalizeFoundationObject(plist)))
    let unwrapped = try #require(unwrapDictionary(payload))

    #expect(unwrapped["URL"] as? String == "https://example.com")
    #expect(unwrapped["ldtext"] as? String == "Example")
}

@Test private func unwrapDictionaryPairsKeysAndObjects() throws {
    let unwrapped = try #require(unwrapDictionary([
        "NS.keys": ["URL", "ldtext", 1],
        "NS.objects": ["https://example.com", "Example", "ignored"],
    ]))

    #expect(unwrapped["URL"] as? String == "https://example.com")
    #expect(unwrapped["ldtext"] as? String == "Example")
    #expect(unwrapped["1"] == nil)
}

@Test private func normalizeFoundationObjectConvertsCommonFoundationTypes() throws {
    let data = try #require("hello".data(using: .utf8))
    let url = try #require(NSURL(string: "https://example.com"))
    let normalized = try #require(normalizeFoundationObject([
        "array": NSArray(array: [url]),
        "data": data as NSData,
    ] as NSDictionary) as? JSONObject)
    let array = try #require(normalized["array"] as? [Any])
    let normalizedURL = try #require(array.first as? JSONObject)

    #expect(normalizedURL["NS.relative"] as? String == "https://example.com")
    #expect(normalized["data"] as? String == "data:;base64,aGVsbG8=")
}
