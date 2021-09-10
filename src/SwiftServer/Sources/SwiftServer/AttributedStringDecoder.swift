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
        guard let nsStr = decoded as? NSAttributedString else {
            return nil // "decoded object type unknown"
        }
        let string = nsStr.string

        var attributes: [Fragment] = []

        // https://github.com/apple/swift-corelibs-foundation/blob/b3b87b6328325b639032bdc92e384f33f0beef0e/Sources/Foundation/AttributedString/Conversion.swift#L222-L251
        var cursor = string.startIndex
        var curScalar = 0
        nsStr.enumerateAttributes(
            in: NSRange(location: 0, length: nsStr.length),
            options: .longestEffectiveRangeNotRequired
        ) { dict, range, _ in
            let nextCursor = string.utf16.index(cursor, offsetBy: range.length)
            let scalarLen = string.unicodeScalars.distance(from: cursor, to: nextCursor)
            for (key, value) in dict {
                attributes.append(
                    Fragment(
                        key: key.rawValue,
                        value: value,
                        scalarRange: curScalar..<(curScalar + scalarLen)
                    )
                )
            }
            cursor = nextCursor
            curScalar += scalarLen
        }

        return attributes
    }
}
