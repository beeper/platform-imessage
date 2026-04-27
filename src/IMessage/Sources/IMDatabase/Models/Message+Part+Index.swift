public extension Message.Part {
    /**
     * represents the value of `__kIMMessagePartAttributeName`; may appear discontinuously
     * if message parts are unsent
     */
    struct Index: RawRepresentable, Hashable, Equatable, Codable, CustomStringConvertible {
        public var rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public var description: String {
            "\(rawValue)"
        }
    }
}

extension Message.Part.Index: Comparable {
    public static func < (lhs: Message.Part.Index, rhs: Message.Part.Index) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
