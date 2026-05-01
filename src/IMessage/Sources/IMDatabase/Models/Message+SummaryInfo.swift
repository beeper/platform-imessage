import Foundation
import OrderedCollections
import IMessageCore

public extension Message {
    struct SummaryInfo: Decodable {
        /// Ordered record representing the structure of the original message
        /// body, present on partially unsent or edited messages.
        ///
        /// The attributed body at this point only reflects the latest state and
        /// completely lacks unsent portions. This data can be used to determine
        /// where to interleave UI indicating that parts of a message were
        /// unsent.
        ///
        /// The property-list keys are ascending numerical strings. The values
        /// describe the starting indexes and lengths of each part of the
        /// original body. This may be a dictionary rather than an array because
        /// other keys may be possible.
        var originalParts: [Part.Index: UnsentPart]?

        /// Indexes in `originalParts` that have been unsent, `rp`.
        var unsentParts: OrderedSet<Part.Index>?

        /// Indexes in `originalParts` that have been edited, `ep`.
        var editedParts: OrderedSet<Part.Index>?

        enum CodingKeys: String, CodingKey {
            case originalParts = "otr"
            case unsentParts = "rp"
            case editedParts = "ep"
        }

        public init(blob: Data) throws {
            // `amc`: observed values include 0 and 3.
            // `ust`: observed value example: 1.
            // `amsa`: observed value example: com.apple.siri.
            // `ams`: observed value example: summarized text.
            // `ec`: message edit history, present for messages that have been
            // partially edited. TODO: check if this is present for edited
            // non-partial messages. The index corresponds to `otr`.

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
        /// The zero-based index pointing to the beginning of this part of the
        /// original message.
        let originalStartIndex: Int
        /// The length of this part of the original message.
        ///
        /// TODO: what is this in? Bytes? UTF-16 code units?
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
