import Foundation
@testable import IMessage
import Testing

@Test func encodeJSONSanitizesMalformedFoundationStrings() throws {
    var unpairedHighSurrogate: [unichar] = [0xD800]
    let malformed = NSString(characters: &unpairedHighSurrogate, length: 1)
    let replacement = "\u{FFFD}"

    let json = try encodeJSON([
        "value": malformed,
        malformed as String: [
            "nested": [malformed],
        ],
    ] as [String: Any])

    let data = try #require(json.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["value"] as? String == replacement)

    let nested = try #require(object[replacement] as? [String: Any])
    let array = try #require(nested["nested"] as? [Any])
    #expect(array.first as? String == replacement)
}
