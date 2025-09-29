/**
 * Trivial wrapper type to avoid logging personal data by accident.
 */
public struct Sensitive<Wrapped> {
    public let kind: Kind
    var wrapped: Wrapped

    init(_ kind: Kind, hiding wrapped: Wrapped) {
        self.kind = kind
        self.wrapped = wrapped
    }

    public func unwrappingSensitiveData() -> Wrapped {
        wrapped
    }
}

extension Sensitive: CustomStringConvertible {
    public var description: String {
        "<private \(kind)>"
    }
}

extension Sensitive: Equatable where Wrapped: Equatable {}

extension Sensitive: Hashable where Wrapped: Hashable {}

public extension Sensitive {
    enum Kind: CaseIterable, Hashable {
        case messageText
        case messageAttributedBody
    }
}
