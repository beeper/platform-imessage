extension Task where Success == Never, Failure == Never {
    static func never() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.max)
        }
    }
}
