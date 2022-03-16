import os

// http://www.russbishop.net/the-law
final class UnfairLock {
    private var _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deallocate()
    }

    func locked<ReturnValue>(_ f: () throws -> ReturnValue) rethrows -> ReturnValue {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try f()
    }

    func tryLock() -> Bool {
        os_unfair_lock_trylock(_lock)
    }

    func lock() {
        os_unfair_lock_unlock(_lock)
    }

    func unlock() {
        os_unfair_lock_unlock(_lock)
    }
}
