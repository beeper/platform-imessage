// TODO: (@pmanot) - Rename
public extension Optional {
    /// Unwraps an optional value, throwing an error if nothing is present.
    func orThrow<E: Error>(_ error: @autoclosure () -> E) throws(E) -> Wrapped {
        guard let unwrapped = self else {
            throw error()
        }

        return unwrapped
    }
}
