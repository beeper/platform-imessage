public extension Optional {
    /// Unwraps an optional value, throwing an error if nothing is present.
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let unwrapped = self else {
            throw error()
        }

        return unwrapped
    }
}
