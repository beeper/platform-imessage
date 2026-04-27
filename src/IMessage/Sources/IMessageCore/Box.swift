/// A trivial wrapper type used to imbue some data with reference semantics or
/// otherwise introduce some indirection.
public class Box<T> {
    public var value: T

    public init(_ value: T) {
        self.value = value
    }
}
