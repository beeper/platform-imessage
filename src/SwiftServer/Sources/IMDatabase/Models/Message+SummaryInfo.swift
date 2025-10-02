import Foundation
import OrderedCollections
import SwiftServerFoundation

public extension Message {
    struct SummaryInfo: Decodable {
        /** present on (partially) unsent/edited messages, `otr` */
        var originalParts: [Part.Index: UnsentPart]?

        /** which parts in `originalParts` have been unsent, `rp` */
        var unsentParts: OrderedSet<Part.Index>?

        /** which parts in `originalParts` have been edited, `ep` */
        var editedParts: OrderedSet<Part.Index>?

        enum CodingKeys: String, CodingKey {
            case originalParts = "otr"
            case unsentParts = "rp"
            case editedParts = "ep"
        }

        public init(blob: Data) throws {
            // `amc`
            // `ust`
            // `amsa`
            // `ams`
            // `ec`: edit history

            var format = PropertyListSerialization.PropertyListFormat.binary
            let plist = try PropertyListSerialization.propertyList(from: blob, options: [], format: &format)
            guard let dict = plist as? [String: Any] else {
                throw ErrorMessage("summary info bplist isn't a dict")
            }

            if let otr = dict["otr"] as? [String: [String: Int]] {
                originalParts = try otr.reduce(into: [:]) { parts, pair in
                    let (index, part) = pair
                    guard let index = Int(index) else {
                        throw ErrorMessage("part index isn't an int: \(index)")
                    }
                    guard let startIndex = part["lo"], let length = part["le"] else {
                        throw ErrorMessage("couldn't decode unsent part at index \(index)")
                    }
                    parts[Part.Index(rawValue: index)] = UnsentPart(originalStartIndex: startIndex, originalLength: length)
                }
            }

            func decodePartIndices(_ decoded: Any?) -> OrderedSet<Message.Part.Index>? {
                guard let indices = decoded as? [Int] else {
                    return nil
                }
                return OrderedSet(indices.map(Part.Index.init))
            }

            unsentParts = decodePartIndices(dict["rp"])
            editedParts = decodePartIndices(dict["ep"])
        }
    }
}

extension Message.SummaryInfo {
    struct UnsentPart: CustomStringConvertible, Equatable, Codable {
        let originalStartIndex: Int
        // what is this in? bytes? UTF-16 code units? etc.
        let originalLength: Int

        var description: String {
            "{@\(originalStartIndex)...\(originalStartIndex + originalLength)}"
        }

        enum CodingKeys: String, CodingKey {
            case originalStartIndex = "lo"
            case originalLength = "le"
        }
    }
}
