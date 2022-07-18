import Foundation

enum AttributedStringDecoder {
    struct Fragment {
        let text: Substring
        let scalarRange: Range<Int>
        let attributes: [String: Any]
    }

    static func decodeAttributedString(from data: Data) throws -> [Fragment] {
        let unarchiver = try NSUnarchiver(forReadingWith: data)
            .orThrow(ErrorMessage("Couldn't create NSUnarchiver"))
        let decoded = try unarchiver.decodeTopLevelObject()
        let nsStr = try (decoded as? NSAttributedString)
            .orThrow(ErrorMessage("Decoded object type unknown"))
        let string = nsStr.string

        var fragments: [Fragment] = []

        // https://github.com/apple/swift-corelibs-foundation/blob/b3b87b6328325b639032bdc92e384f33f0beef0e/Sources/Foundation/AttributedString/Conversion.swift#L222-L251
        var cursor = string.startIndex
        var curScalar = 0
        nsStr.enumerateAttributes(
            in: NSRange(location: 0, length: nsStr.length),
            options: .longestEffectiveRangeNotRequired
        ) { dict, range, _ in
            let nextCursor = string.utf16.index(cursor, offsetBy: range.length)
            let scalarLen = string.unicodeScalars.distance(from: cursor, to: nextCursor)
            var attributes: [String: Any] = [:]
            for (key, value) in dict {
                attributes[key.rawValue] = value
            }
            fragments.append(Fragment(
                text: string[cursor..<nextCursor],
                scalarRange: curScalar..<(curScalar + scalarLen),
                attributes: attributes
            ))
            cursor = nextCursor
            curScalar += scalarLen
        }

        return fragments
    }
}
