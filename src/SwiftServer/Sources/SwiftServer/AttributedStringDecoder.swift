import Foundation
import ExceptionCatcher
import SwiftServerFoundation

enum AttributedStringDecoder {
    struct Fragment {
        let text: Substring
        let scalarRange: Range<Int>
        let attributes: [String: Any]
    }

    static func decodeAttributedString(from data: Data) throws -> [Fragment] {
        let unarchiver = try NSUnarchiver(forReadingWith: data)
            .orThrow(ErrorMessage("Couldn't create NSUnarchiver"))
        let decoded = try ExceptionCatcher.catch { unarchiver.decodeObject() }
        let nsStr = try (decoded as? NSAttributedString)
            .orThrow(ErrorMessage("Decoded object type unknown"))
        let string = nsStr.string

        var fragments: [Fragment] = []
        // https://github.com/apple/swift-corelibs-foundation/blob/b3b87b6328325b639032bdc92e384f33f0beef0e/Sources/Foundation/AttributedString/Conversion.swift#L222-L251
        nsStr.enumerateAttributes(
            in: NSRange(location: 0, length: nsStr.length),
            options: .longestEffectiveRangeNotRequired
        ) { dict, range, _ in
            guard let stringRange = Range(range, in: string) else {
                return
            }
            let scalarStart = string.unicodeScalars.distance(from: string.startIndex, to: stringRange.lowerBound)
            let scalarEnd = string.unicodeScalars.distance(from: string.startIndex, to: stringRange.upperBound)
            var attributes: [String: Any] = [:]
            for (key, value) in dict {
                attributes[key.rawValue] = value
            }
            fragments.append(Fragment(
                text: string[stringRange],
                scalarRange: scalarStart..<scalarEnd,
                attributes: attributes
            ))
        }
        return fragments
    }
}
