// this probably introduces at least two pointer indirections because of
// allocation, but it's probably ok. our platform target doesn't let us use
// `OSAllocatedUnfairLock` nor `Mutex`
public final class Protected<Protecting>: @unchecked Sendable {
    private nonisolated(unsafe) var guts: Protecting
    private var lock = UnfairLock()

    public init(_ initialValue: Protecting) {
        self.guts = initialValue
    }

    public convenience init<T>() where Protecting == T? {
        self.init(nil)
    }

    public func withLock<T>(_ work: (inout Protecting) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work(&guts)
    }
}

public extension Protected {
    func read() -> Protecting {
        withLock { $0 }
    }
}
