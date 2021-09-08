import Foundation

enum AttributedStringDecoder {
    struct Fragment {
        let key: String
        let value: Any
        let scalarRange: Range<Int>
    }

    static func decodeAttributedString(from data: Data) throws -> [Fragment]? {
        let unarchiver = NSUnarchiver(forReadingWith: data)!
        let decoded = unarchiver.decodeObject()
        guard let str = decoded as? NSAttributedString else {
            return nil // "decoded object type unknown"
        }

        var attributes: [Fragment] = []

        let strSwift = str.string
        let strScalars = strSwift.unicodeScalars
        let scalarIndices = Array(strScalars.indices)

        func scalarIndex(for stringIndex: String.Index) -> Int {
            let pos = stringIndex.samePosition(in: strScalars)!
            return scalarIndices.firstIndex(of: pos) ?? scalarIndices.count
        }

        str.enumerateAttributes(
            in: NSRange(location: 0, length: str.length),
            options: .longestEffectiveRangeNotRequired
        ) { dict, range, _ in
            let strRange = Range(range, in: strSwift)!
            let lower = scalarIndex(for: strRange.lowerBound)
            let upper = scalarIndex(for: strRange.upperBound)
            for (key, value) in dict {
                attributes.append(
                    Fragment(
                        key: key.rawValue,
                        value: value,
                        scalarRange: lower..<upper
                    )
                )
            }
        }
        return attributes
    }
}
