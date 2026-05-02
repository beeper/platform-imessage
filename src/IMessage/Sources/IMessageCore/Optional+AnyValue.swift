/// A type-erasing protocol that lets generic code inspect any `Optional`
/// without knowing its `Wrapped` type at compile time.
public protocol OptionalProtocol {
    var anyValue: Any? { get }
}

extension Optional: OptionalProtocol {
    public var anyValue: Any? {
        switch self {
        case .some(let value): return value
        case .none: return nil
        }
    }
}
