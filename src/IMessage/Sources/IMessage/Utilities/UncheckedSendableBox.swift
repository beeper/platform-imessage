/// Wraps non-Sendable values for concurrency hops where callers guarantee safe use.
package final class UncheckedSendableBox<Value>: @unchecked Sendable {
    package let value: Value

    package init(_ value: Value) {
        self.value = value
    }
}

/// Weak counterpart of `UncheckedSendableBox`, for `[weak self]`-style hops into
/// `@Sendable` closures (e.g. lane closures that must not retain their
/// lane-confined `MessagesController`). Same contract: the caller guarantees the
/// value is only used from its confinement domain.
package final class WeakUncheckedSendableBox<Value: AnyObject>: @unchecked Sendable {
    package private(set) weak var value: Value?

    package init(_ value: Value) {
        self.value = value
    }
}
