/// Wraps non-Sendable values for concurrency hops where callers guarantee safe use.
package final class UncheckedSendableBox<Value>: @unchecked Sendable {
    package let value: Value

    package init(_ value: Value) {
        self.value = value
    }
}
