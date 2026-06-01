import Carbon.HIToolbox.Events
import Dispatch
import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "key-presser")

enum KeyPresser {
    static let src = CGEventSource(stateID: .hidSystemState)

    private static func perform(onMainThread: Bool, _ action: () throws -> Void) rethrows {
        guard onMainThread, !Thread.isMainThread else {
            try action()
            return
        }
        log.debug("dispatching simulated keypress to main thread (queueName=\(__dispatch_queue_get_label(nil)))")
        try DispatchQueue.main.sync {
            try action()
        }
        return
    }

    private static func post(to pid: pid_t, key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        log.debug("sending simulated keypress (code=\(key))")
        for keyDown in [true, false] {
            log.debug("simulated keypress phase (code=\(key), down=\(keyDown))")
            // all events will not be posted for _some_ users if `keyboardEventSource` is nil

            let event: CGEvent = try CGEvent(keyboardEventSource: Self.src, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            if let flags { event.flags = flags }
            event.postToPid(pid)

            if MacOSVersion.isAtLeast(.sequoia), !keyDown { // workaround courtesy https://github.com/pmanot
                event.flags = []
                event.postToPid(pid)
            }
        }
    }

    private static func press(to pid: pid_t, key: CGKeyCode, flags: CGEventFlags? = nil, onMainThread: Bool = true) throws {
        try perform(onMainThread: onMainThread) {
            try post(to: pid, key: key, flags: flags)
        }
    }

    private static func pressMappedKey(_ key: Character, to pid: pid_t, flags: CGEventFlags? = nil, onMainThread: Bool = true) throws {
        try perform(onMainThread: onMainThread) {
            guard let keyCode = KeyMap.shared[key] else { return }
            try post(to: pid, key: CGKeyCode(keyCode), flags: flags)
        }
    }

    static func sendReturn(to pid: pid_t, onMainThread: Bool = true) throws {
        try press(to: pid, key: CGKeyCode(kVK_Return), onMainThread: onMainThread)
    }

    static func sendDownArrow(to pid: pid_t, onMainThread: Bool = true) throws {
        try press(to: pid, key: CGKeyCode(kVK_DownArrow), onMainThread: onMainThread)
    }

    static func sendRightArrow(to pid: pid_t, onMainThread: Bool = true) throws {
        try press(to: pid, key: CGKeyCode(kVK_RightArrow), onMainThread: onMainThread)
    }

    static func sendCommandV(to pid: pid_t, onMainThread: Bool = true) throws {
        // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
        try pressMappedKey("v", to: pid, flags: .maskCommand, onMainThread: onMainThread)
    }

    /// marks as read/unread on ventura
    static func sendCommandShiftU(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("u", to: pid, flags: [.maskCommand, .maskShift], onMainThread: onMainThread)
    }

    /// selects next thread, both keys aren't the same in practice
    static func sendCommandRightBracket(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("]", to: pid, flags: .maskCommand, onMainThread: onMainThread)
    }

    #if false
    /// selects first thread
    static func sendCommand1(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("1", to: pid, flags: .maskCommand, onMainThread: onMainThread)
    }
    /// edits selected message
    static func sendCommandE(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("e", to: pid, flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects prev thread, both keys aren't the same in practice
    static func sendCommandLeftBracket(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("[", to: pid, flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects first non-pinned thread
    static func sendCommandOption1(to pid: pid_t, onMainThread: Bool = true) throws {
        try pressMappedKey("1", to: pid, flags: [.maskCommand, .maskAlternate], onMainThread: onMainThread)
    }
    static func sendControlShiftTab(to pid: pid_t, onMainThread: Bool = true) throws {
        try press(to: pid, key: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift], onMainThread: onMainThread)
    }
    static func sendControlTab(to pid: pid_t, onMainThread: Bool = true) throws {
        try press(to: pid, key: CGKeyCode(kVK_Tab), flags: .maskControl, onMainThread: onMainThread)
    }
    #endif
}
