import os
import Foundation
import CUnfairLock

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
        // based on https://hacks.mozilla.org/2022/10/improving-firefox-responsiveness-on-macos/
        os_unfair_lock_lock_with_options(
            _lock,
            OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION | OS_UNFAIR_LOCK_ADAPTIVE_SPIN
        )
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
