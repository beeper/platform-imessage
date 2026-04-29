import ExceptionCatcher
import Foundation
import IMessageCore

public enum AttributedBodyDecoder {
    public struct Fragment {
        public let text: Substring
        public let scalarRange: Range<Int>
        public let attributes: [String: Any]
    }

    public static func attributedString(from data: Data) throws -> NSAttributedString {
        guard let unarchiver = NSUnarchiver(forReadingWith: data) else {
            throw ErrorMessage("couldn't create NSUnarchiver")
        }

        // this is technically unsafe (https://iosdevelopers.slack.com/archives/C031X84F6/p1658329958824499?thread_ts=1658147279.256379&cid=C031X84F6)
        let decodedObject = try ExceptionCatcher.catch { unarchiver.decodeObject() }

        guard let decodedAttributedString: NSAttributedString = decodedObject as? NSAttributedString else {
            throw ErrorMessage("couldn't cast to attributed string (was actually \(type(of: decodedObject)))")
        }

        return decodedAttributedString
    }

    public static func plainText(from data: Data) throws -> String {
        try attributedString(from: data).string
    }

    public static func fragments(from data: Data) throws -> [Fragment] {
        let attributedString = try attributedString(from: data)
        let string = attributedString.string

        var fragments: [Fragment] = []
        // https://github.com/apple/swift-corelibs-foundation/blob/b3b87b6328325b639032bdc92e384f33f0beef0e/Sources/Foundation/AttributedString/Conversion.swift#L222-L251
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
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
