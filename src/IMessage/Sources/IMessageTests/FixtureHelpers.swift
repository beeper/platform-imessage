import Foundation
import Testing

typealias FixtureJSONObject = [String: Any]

func loadFixture(_ name: String) throws -> [Any] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    let data = try Data(contentsOf: url)
    var values = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    if var msgRow = values.first as? FixtureJSONObject {
        try hydrateFixtureBlobs(in: &msgRow)
        values[0] = msgRow
    }
    return values
}

private func hydrateFixtureBlobs(in row: inout FixtureJSONObject) throws {
    for key in ["attributedBody", "message_summary_info", "payload_data", "properties"] {
        guard let value = row[key] as? String else {
            continue
        }
        row[key] = try dataURIStringToData(value, key: key)
    }
}

private func dataURIStringToData(_ value: String, key: String) throws -> Data {
    let prefix = "data:;base64,"
    guard value.hasPrefix(prefix),
          let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else {
        throw FixtureError.invalidDataURI(key: key)
    }
    return data
}

private enum FixtureError: Error {
    case invalidDataURI(key: String)
}
