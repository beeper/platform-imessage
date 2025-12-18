import AppKit
import Carbon.HIToolbox.Events
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "key-presser")

extension NSRunningApplication {
    /// Posts a synthesized key down/up pair to this app's pid.
    public func press(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        let pid = processIdentifier
        guard pid > 0 else { throw ErrorMessage("NSRunningApplication has no processIdentifier") }
        
        try runOnMainThread {
            log.debug("sending simulated keypress (pid=\(pid), code=\(key))")
            
            for keyDown in [true, false] {
                log.debug("simulated keypress phase (pid=\(pid), code=\(key), down=\(keyDown))")
                
                // Events may not be posted reliably for some users if keyboardEventSource is nil.
                let event = try CGEvent(
                    keyboardEventSource: KeyPresser.src,
                    virtualKey: key,
                    keyDown: keyDown
                ).orThrow(ErrorMessage("key \(key) event empty"))
                
                if let flags { event.flags = flags }
                
                event.postToPid(pid)
                
                // Workaround for macOS 15 Sequoia: ensure keyUp is delivered correctly.
                if MacOSVersion.isAtLeast(.sequoia), !keyDown {
                    event.flags = []
                    event.postToPid(pid)
                }
            }
        }
    }
    
    /// Presses a higher-level key combination into this app.
    public func press(_ combo: KeyPresser.Combo) throws {
        guard let resolved = combo.resolved else {
            log.debug("unable to resolve key combo \(String(describing: combo)) (no-op)")
            return
        }
        try press(key: resolved.key, flags: resolved.flags)
    }
}

public enum KeyPresser {
    /// Keep a non-nil source around; nil source can cause events to not post for some users.
    static let src = CGEventSource(stateID: .hidSystemState)
    
    /// Common key combos as a single enum instead of lots of methods.
    public enum Combo: Sendable {
        /// Post a specific virtual key code + optional flags.
        case keyCode(CGKeyCode, flags: CGEventFlags? = nil)
        
        /// Layout-aware character -> key code via KeyMap (no-op if unmapped).
        case character(Character, flags: CGEventFlags? = nil)
        
        case `return`
        case tab
        case downArrow
        case rightArrow
        
        case commandV
        case commandShiftU
        case commandRightBracket
        
        fileprivate var resolved: (key: CGKeyCode, flags: CGEventFlags?)? {
            switch self {
                case let .keyCode(key, flags):
                    return (key, flags)
                    
                case let .character(ch, flags):
                    guard let keyCode = KeyMap.shared[ch] else { return nil }
                    return (CGKeyCode(keyCode), flags)
                    
                case .return:
                    return (CGKeyCode(kVK_Return), nil)
                    
                case .tab:
                    return (CGKeyCode(kVK_Tab), nil)
                    
                case .downArrow:
                    return (CGKeyCode(kVK_DownArrow), nil)
                    
                case .rightArrow:
                    return (CGKeyCode(kVK_RightArrow), nil)
                    
                case .commandV:
                    // sending kVK_ANSI_V won't work on non-qwerty layouts where V is elsewhere
                    guard let keyCode = KeyMap.shared["v"] else { return nil }
                    return (CGKeyCode(keyCode), .maskCommand)
                    
                case .commandShiftU:
                    guard let keyCode = KeyMap.shared["u"] else { return nil }
                    return (CGKeyCode(keyCode), [.maskCommand, .maskShift])
                    
                case .commandRightBracket:
                    guard let keyCode = KeyMap.shared["]"] else { return nil }
                    return (CGKeyCode(keyCode), .maskCommand)
            }
        }
    }
    
    /// Convenience: namespace entrypoint.
    public static func press(_ combo: Combo, to app: NSRunningApplication) throws {
        try app.press(combo)
    }
    
    /// Convenience: if you only have a pid.
    public static func press(_ combo: Combo, toPid pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw ErrorMessage("no running application for pid \(pid)")
        }
        try app.press(combo)
    }
}


// TODO: refactor
class LegacyKeyPresser {
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
            let event = try CGEvent(keyboardEventSource: Self.src, virtualKey: key, keyDown: keyDown)
                .orThrow(ErrorMessage("key \(key) event empty"))
            
            if let flags {
                event.flags = flags
            }
            
            event.postToPid(self.pid)
            
            if MacOSVersion.isAtLeast(.sequoia), !keyDown { // workaround courtesy https://github.com/pmanot
                event.flags = []
                event.postToPid(self.pid)
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
