import os
import Foundation

// http://www.russbishop.net/the-law
final class UnfairLock: NSLocking {
    private var _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    func tryLock() -> Bool {
        os_unfair_lock_trylock(_lock)
    }

    func lock() {
        os_unfair_lock_lock(_lock)
    }

    func unlock() {
        os_unfair_lock_unlock(_lock)
    }

    func lock<ReturnValue>(_ f: () throws -> ReturnValue) rethrows -> ReturnValue {
        lock()
        defer { unlock() }
        return try f()
    }
}
