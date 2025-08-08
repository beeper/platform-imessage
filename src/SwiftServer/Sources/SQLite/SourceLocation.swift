public struct SourceLocation {
    var id: String?

    public init() {
        self.id = nil
    }

    public init(in file: StaticString, line: Int) {
        self.id = "\(file):\(line)"
    }

    public init(opaque: String) {
        self.id = opaque
    }

    public static var anywhere: Self {
        SourceLocation()
    }
}

extension SourceLocation: CustomStringConvertible {
    public var description: String {
        if let id {
            "(\(id))"
        } else {
            "(anywhere)"
        }
    }
}

extension SourceLocation: Equatable {
    // we don't care about converting source locations; they're only kept for
    // diagnostic purposes. this also means we can use synthesized conformances
    // for `Equatable` without having to worry about excluding this information
    // from comparison
    public static func == (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        true
    }
}
