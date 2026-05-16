import Carbon.HIToolbox.Events
import Dispatch
import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "key-presser")

// TODO: refactor
class KeyPresser {
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }

    static let src = CGEventSource(stateID: .hidSystemState)

    private func perform(onMainThread: Bool, _ action: () throws -> Void) rethrows {
        guard onMainThread, !Thread.isMainThread else {
            return try action()
        }
        log.debug("dispatching simulated keypress to main thread (queueName=\(__dispatch_queue_get_label(nil)))")
        try DispatchQueue.main.sync {
            try action()
        }
        return
    }

    private func post(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        log.debug("sending simulated keypress (code=\(key))")
        for keyDown in [true, false] {
            log.debug("simulated keypress phase (code=\(key), down=\(keyDown))")
            // all events will not be posted for _some_ users if `keyboardEventSource` is nil
            let ev = try CGEvent(keyboardEventSource: Self.src, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            if let flags { ev.flags = flags }
            ev.postToPid(self.pid)
            if isSequoiaOrUp, !keyDown { // workaround courtesy https://github.com/pmanot
                ev.flags = []
                ev.postToPid(self.pid)
            }
        }
    }

    private func press(key: CGKeyCode, flags: CGEventFlags? = nil, onMainThread: Bool = true) throws {
        try perform(onMainThread: onMainThread) {
            try post(key: key, flags: flags)
        }
    }

    private func pressMappedKey(_ key: Character, flags: CGEventFlags? = nil, onMainThread: Bool = true) throws {
        try perform(onMainThread: onMainThread) {
            guard let keyCode = KeyMap.shared[key] else { return }
            try post(key: CGKeyCode(keyCode), flags: flags)
        }
    }

    func `return`(onMainThread: Bool = true) throws {
        try press(key: CGKeyCode(kVK_Return), onMainThread: onMainThread)
    }

    func downArrow(onMainThread: Bool = true) throws {
        try press(key: CGKeyCode(kVK_DownArrow), onMainThread: onMainThread)
    }

    func rightArrow(onMainThread: Bool = true) throws {
        try press(key: CGKeyCode(kVK_RightArrow), onMainThread: onMainThread)
    }

    func commandV(onMainThread: Bool = true) throws {
        // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
        try pressMappedKey("v", flags: .maskCommand, onMainThread: onMainThread)
    }

    /// marks as read/unread on ventura
    func commandShiftU(onMainThread: Bool = true) throws {
        try pressMappedKey("u", flags: [.maskCommand, .maskShift], onMainThread: onMainThread)
    }

    /// selects next thread, both keys aren't the same in practice
    func commandRightBracket(onMainThread: Bool = true) throws {
        try pressMappedKey("]", flags: .maskCommand, onMainThread: onMainThread)
    }

    #if false
    /// selects first thread
    func command1(onMainThread: Bool = true) throws {
        try pressMappedKey("1", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// edits selected message
    func commandE(onMainThread: Bool = true) throws {
        try pressMappedKey("e", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects prev thread, both keys aren't the same in practice
    func commandLeftBracket(onMainThread: Bool = true) throws {
        try pressMappedKey("[", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects first non-pinned thread
    func commandOption1(onMainThread: Bool = true) throws {
        try pressMappedKey("1", flags: [.maskCommand, .maskAlternate], onMainThread: onMainThread)
    }
    func ctrlShiftTab(onMainThread: Bool = true) throws {
        try press(key: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift], onMainThread: onMainThread)
    }
    func ctrlTab(onMainThread: Bool = true) throws {
        try press(key: CGKeyCode(kVK_Tab), flags: .maskControl, onMainThread: onMainThread)
    }
    #endif
}
