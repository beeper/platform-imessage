extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        if let wrapped = self {
            return wrapped
        } else {
            throw error()
        }
    }
}

// will be optimized out in release mode
@_transparent
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard SwiftServer.isLoggingEnabled else { return }
    print(message())
    #endif
}
