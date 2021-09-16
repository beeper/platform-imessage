extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        if let wrapped = self {
            return wrapped
        } else {
            throw error()
        }
    }
}
