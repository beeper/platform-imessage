import Carbon.HIToolbox.Events
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "key-presser")

// TODO: refactor
class KeyPresser {
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }

    static let src = CGEventSource(stateID: .hidSystemState)

    private func press(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        log.debug("sending simulated keypress (code=\(key))")
        for keyDown in [true, false] {
            log.debug("simulated keypress phase (code=\(key), down=\(keyDown))")
            // all events will not be posted for _some_ users if `keyboardEventSource` is nil
            let ev = try CGEvent(keyboardEventSource: Self.src, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            if let flags { ev.flags = flags }
            ev.postToPid(self.pid)
            if MacOSVersion.isAtLeast(.sequoia), !keyDown { // workaround courtesy https://github.com/pmanot
                ev.flags = []
                ev.postToPid(self.pid)
            }
        }
    }

    func `return`() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Return))
        }
    }

    func downArrow() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_DownArrow))
        }
    }

    func rightArrow() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_RightArrow))
        }
    }

    func tab() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Tab))
        }
    }

    func commandV() throws {
        try runOnMainThread {
            // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
            guard let keyCode = KeyMap.shared["v"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }

    /// marks as read/unread on ventura
    func commandShiftU() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["u"] else { return }
            try press(key: CGKeyCode(keyCode), flags: [.maskCommand, .maskShift])
        }
    }

    /// selects next thread, both keys aren't the same in practice
    func commandRightBracket() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["]"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }

    #if false
    /// selects first thread
    func command1() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["1"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    /// edits selected message
    func commandE() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["e"] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    /// selects prev thread, both keys aren't the same in practice
    func commandLeftBracket() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["["] else { return }
            try press(key: CGKeyCode(keyCode), flags: .maskCommand)
        }
    }
    /// selects first non-pinned thread
    func commandOption1() throws {
        try runOnMainThread {
            guard let keyCode = KeyMap.shared["1"] else { return }
            try press(key: CGKeyCode(keyCode), flags: [.maskCommand, .maskAlternate])
        }
    }
    func ctrlShiftTab() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift])
        }
    }
    func ctrlTab() throws {
        try runOnMainThread {
            try press(key: CGKeyCode(kVK_Tab), flags: .maskControl)
        }
    }
    #endif
}
