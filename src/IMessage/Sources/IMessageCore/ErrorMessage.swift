/// A trivial wrapper around ``String`` for throwing.
public struct ErrorMessage: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        Log.errors.error("<!> \(description)")
        self.description = description
    }
}
