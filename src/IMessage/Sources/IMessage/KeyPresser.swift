import Carbon.HIToolbox.Events
import Dispatch
import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "key-presser")

class KeyPresser {
    let pid: pid_t
    private let postKeyEvents: (CGKeyCode, CGEventFlags?) throws -> Void
    private let keyCodeForCharacter: (Character) -> UInt16?

    init(
        pid: pid_t,
        postKeyEvents: ((CGKeyCode, CGEventFlags?) throws -> Void)? = nil,
        keyCodeForCharacter: ((Character) -> UInt16?)? = nil
    ) {
        self.pid = pid
        self.postKeyEvents = postKeyEvents ?? { key, flags in
            try Self.post(key: key, flags: flags, to: pid)
        }
        self.keyCodeForCharacter = keyCodeForCharacter ?? { KeyMap.shared[$0] }
    }

    static let src = CGEventSource(stateID: .hidSystemState)

    private func perform<T>(onMainThread: Bool, _ action: () throws -> T) rethrows -> T {
        guard onMainThread, !Thread.isMainThread else {
            return try action()
        }
        log.debug("dispatching simulated keypress to main thread (queueName=\(__dispatch_queue_get_label(nil)))")
        return try DispatchQueue.main.sync {
            try action()
        }
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags? = nil, to pid: pid_t) throws {
        log.debug("sending simulated keypress (code=\(key))")
        for keyDown in [true, false] {
            log.debug("simulated keypress phase (code=\(key), down=\(keyDown))")
            // all events will not be posted for _some_ users if `keyboardEventSource` is nil
            let ev = try CGEvent(keyboardEventSource: Self.src, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            if let flags { ev.flags = flags }
            ev.postToPid(pid)
            if isSequoiaOrUp, !keyDown { // workaround courtesy https://github.com/pmanot
                ev.flags = []
                ev.postToPid(pid)
            }
        }
    }

    private func press(key: CGKeyCode, flags: CGEventFlags? = nil, onMainThread: Bool) throws {
        try perform(onMainThread: onMainThread) {
            try postKeyEvents(key, flags)
        }
    }

    private func pressMappedKey(_ key: Character, flags: CGEventFlags? = nil, onMainThread: Bool) throws {
        guard let keyCode = perform(onMainThread: true, { keyCodeForCharacter(key) }) else { return }
        try press(key: CGKeyCode(keyCode), flags: flags, onMainThread: onMainThread)
    }

    func `return`(onMainThread: Bool = false) throws {
        try press(key: CGKeyCode(kVK_Return), onMainThread: onMainThread)
    }

    func downArrow(onMainThread: Bool = false) throws {
        try press(key: CGKeyCode(kVK_DownArrow), onMainThread: onMainThread)
    }

    func rightArrow(onMainThread: Bool = false) throws {
        try press(key: CGKeyCode(kVK_RightArrow), onMainThread: onMainThread)
    }

    func commandV(onMainThread: Bool = false) throws {
        // sending CGKeyCode(kVK_ANSI_V) won't work on non-qwerty layouts where V key is in a different place
        try pressMappedKey("v", flags: .maskCommand, onMainThread: onMainThread)
    }

    /// marks as read/unread on ventura
    func commandShiftU(onMainThread: Bool = false) throws {
        try pressMappedKey("u", flags: [.maskCommand, .maskShift], onMainThread: onMainThread)
    }

    /// selects next thread, both keys aren't the same in practice
    func commandRightBracket(onMainThread: Bool = false) throws {
        try pressMappedKey("]", flags: .maskCommand, onMainThread: onMainThread)
    }

    #if false
    /// selects first thread
    func command1(onMainThread: Bool = false) throws {
        try pressMappedKey("1", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// edits selected message
    func commandE(onMainThread: Bool = false) throws {
        try pressMappedKey("e", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects prev thread, both keys aren't the same in practice
    func commandLeftBracket(onMainThread: Bool = false) throws {
        try pressMappedKey("[", flags: .maskCommand, onMainThread: onMainThread)
    }
    /// selects first non-pinned thread
    func commandOption1(onMainThread: Bool = false) throws {
        try pressMappedKey("1", flags: [.maskCommand, .maskAlternate], onMainThread: onMainThread)
    }
    func ctrlShiftTab(onMainThread: Bool = false) throws {
        try press(key: CGKeyCode(kVK_Tab), flags: [.maskControl, .maskShift], onMainThread: onMainThread)
    }
    func ctrlTab(onMainThread: Bool = false) throws {
        try press(key: CGKeyCode(kVK_Tab), flags: .maskControl, onMainThread: onMainThread)
    }
    #endif
}
