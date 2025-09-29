extension Task where Success == Never, Failure == Never {
    static func never() async {
        let empty = AsyncStream<Never> { _ in }
        for await _ in empty {}
    }
}
