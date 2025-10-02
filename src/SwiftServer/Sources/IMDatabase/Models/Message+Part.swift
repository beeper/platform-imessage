import Foundation
import Logging

private let log = Logger(swiftServerLabel: "imdb.models")

public extension Message {
    struct Part {
        public let index: Index
        /** whether this part is represented by `U+FFFC` within the message's `attributedBody` and or `text`. */
        public let replacedWithObject: Bool
        /** the GUID of the message this part is from. */
        public let parentMessageGUID: GUID<Message>
        public let rangeWithinParentAttributedBody: NSRange
        /** a substring of the parent message's `attributedBody` that forms this part's textual content. directly corresponds to `rangeWithinParentAttributedBody`. */
        public let attributedSubstring: NSAttributedString

        init(of parent: Message, in attributedBody: NSAttributedString, at range: NSRange, index: Index) {
            let partText = attributedBody.attributedSubstring(from: range)

            self.index = index
            let objectReplacementCharacter: Character = "\u{fffc}"
            self.replacedWithObject = partText.string == "\(objectReplacementCharacter)"
            self.parentMessageGUID = parent.guid
            self.rangeWithinParentAttributedBody = range
            self.attributedSubstring = partText
        }

        /** if this part refers to an attachment (also implies `isEmbeddedObject`), the GUID of the `attachment` */
        var attachmentGUID: GUID<Attachment>? {
            guard let value = attributedSubstring.attribute(.imFileTransferGUID, at: 0, effectiveRange: nil) as? String else {
                return nil
            }
            return GUID(value)
        }
    }
}

extension Message.Part: Equatable {
    public static func == (lhs: Message.Part, rhs: Message.Part) -> Bool {
        lhs.index == rhs.index && lhs.parentMessageGUID == rhs.parentMessageGUID
    }
}

extension Message.Part: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(parentMessageGUID)
        hasher.combine(index)
    }
}
