import Foundation
import ArgumentParser
import CoreGraphics
import AppKit
import Carbon
import Combine

// MARK: - OS Version Detection

private let isSequoiaOrUp: Bool = {
    if #available(macOS 15, *) {
        return true
    }
    return false
}()

// MARK: - Keyboard Layout Mapping

/// Maps characters to key codes based on the current keyboard layout
/// This is necessary because key codes are physical positions, not characters
private final class KeyMap {
    private static let keyCodeRange: Range<UInt16> = 0..<127

    static let shared = KeyMap()
    private init() {}

    private var cached: (String, [UTF16.CodeUnit: UInt16])?

    private func makeMap(source: TISInputSource) -> [UTF16.CodeUnit: UInt16] {
        var dict: [UTF16.CodeUnit: UInt16] = [:]
        guard let layoutDataRaw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRaw).takeUnretainedValue() as Data
        layoutData.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for keyCode in Self.keyCodeRange {
                var deadKeyState: UInt32 = 0
                var length = 0
                var char: UTF16.CodeUnit = 0
                let err = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0, // modifierKeyState
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    1,
                    &length,
                    &char
                )
                guard err == noErr else { continue }
                dict[char] = keyCode
            }
        }
        return dict
    }

    subscript(key: Character) -> UInt16? {
        guard let utf16 = key.utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        let map: [UTF16.CodeUnit: UInt16]
        if let _map = cached, _map.0 == id {
            map = _map.1
        } else {
            map = makeMap(source: source)
            cached = (id, map)
        }
        return map[utf16]
    }
}

// MARK: - Shared Event Source

private let sharedEventSource = CGEventSource(stateID: .hidSystemState)

// MARK: - App Activation Helper

private extension NSRunningApplication {
    /// Activates the application and waits for it to become active using KVO via Combine
    func activateAndWait(timeoutSeconds: TimeInterval = 2.0) async throws {
        // If already active, return immediately
        if isActive { return }

        activate(options: [.activateIgnoringOtherApps])

        // Use Combine publisher with continuation to wait for activation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var cancellable: AnyCancellable?

            cancellable = self.publisher(for: \.isActive)
                .filter { $0 }
                .setFailureType(to: KeyError.self)
                .timeout(.seconds(timeoutSeconds), scheduler: DispatchQueue.main, customError: { .activationTimeout })
                .first()
                .sink(
                    receiveCompletion: { completion in
                        switch completion {
                        case .finished:
                            break
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { _ in
                        continuation.resume()
                        cancellable?.cancel()
                    }
                )
        }

        // Small additional delay to ensure app is ready to receive events
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

extension AXDump {
    struct Key: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Send keyboard input to an application",
            discussion: """
                Send key presses and keyboard shortcuts to an application.
                The application must be frontmost to receive key events.

                KEY NAMES:
                  Letters/Numbers: a-z, 0-9
                  Special keys: enter, return, tab, space, escape, delete, backspace
                  Arrow keys: up, down, left, right
                  Function keys: f1-f12
                  Navigation: home, end, pageup, pagedown

                MODIFIERS (combine with +):
                  cmd, command    - Command key (⌘)
                  ctrl, control   - Control key (⌃)
                  opt, option, alt - Option key (⌥)
                  shift           - Shift key (⇧)

                EXAMPLES:
                  axdump key 710 enter                    Press Enter
                  axdump key 710 "cmd+c"                  Copy (⌘C)
                  axdump key 710 "cmd+v"                  Paste (⌘V)
                  axdump key 710 "cmd+shift+s"            Save As (⌘⇧S)
                  axdump key 710 "cmd+a" "cmd+c"          Select All then Copy
                  axdump key 710 tab tab enter            Tab twice then Enter
                  axdump key 710 --type "Hello World"     Type text
                  axdump key 710 escape                   Press Escape
                """
        )

        @Argument(help: "Process ID of the application")
        var pid: Int32

        @Argument(parsing: .remaining, help: "Key(s) to press (e.g., 'enter', 'cmd+c', 'cmd+shift+s')")
        var keys: [String] = []

        @Option(name: .long, help: "Type a string of text character by character")
        var type: String?

        @Option(name: [.customShort("d"), .long], help: "Delay between key presses in milliseconds (default: 50)")
        var delay: Int = 50

        @Flag(name: .shortAndLong, help: "Activate the application before sending keys")
        var activate: Bool = false

        @Flag(name: .long, help: "List all known key names")
        var listKeys: Bool = false

        func run() async throws {
            if listKeys {
                printKeyList()
                return
            }

            guard !keys.isEmpty || type != nil else {
                print("Error: No keys specified. Use positional arguments or --type")
                throw ExitCode.failure
            }

            // Find the application
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "").first(where: { $0.processIdentifier == pid }) ??
                  NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
                print("Error: Could not find application with PID \(pid)")
                throw ExitCode.failure
            }

            // Activate if requested
            if activate {
                do {
                    try await app.activateAndWait()
                } catch KeyError.activationTimeout {
                    print("Warning: Application may not have activated in time")
                }
            }

            // Type string if specified
            if let text = type {
                for char in text {
                    try sendCharacter(char)
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
                print("Typed: \(text)")
            }

            // Send key presses
            for keySpec in keys {
                let (keyCode, modifiers) = try parseKeySpec(keySpec)
                try await sendKey(keyCode: keyCode, modifiers: modifiers)
                print("Pressed: \(keySpec)")

                if delay > 0 && keySpec != keys.last {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
            }
        }

        private func parseKeySpec(_ spec: String) throws -> (CGKeyCode, CGEventFlags) {
            let parts = spec.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }

            var modifiers: CGEventFlags = []
            var keyName: String = ""

            for part in parts {
                switch part {
                case "cmd", "command":
                    modifiers.insert(.maskCommand)
                case "ctrl", "control":
                    modifiers.insert(.maskControl)
                case "opt", "option", "alt":
                    modifiers.insert(.maskAlternate)
                case "shift":
                    modifiers.insert(.maskShift)
                default:
                    keyName = part
                }
            }

            guard let keyCode = keyCodeFor(keyName) else {
                throw KeyError.unknownKey(keyName)
            }

            return (keyCode, modifiers)
        }

        private func keyCodeFor(_ name: String) -> CGKeyCode? {
            // Special keys with fixed key codes (these are physical keys, not characters)
            let specialKeyMap: [String: CGKeyCode] = [
                // Special keys
                "return": 36, "enter": 36,
                "tab": 48,
                "space": 49,
                "delete": 51, "backspace": 51,
                "escape": 53, "esc": 53,
                "forwarddelete": 117,

                // Function keys
                "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
                "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,

                // Arrow keys
                "left": 123, "right": 124, "down": 125, "up": 126,

                // Navigation
                "home": 115, "end": 119, "pageup": 116, "pagedown": 121,

                // Keypad
                "kp0": 82, "kp1": 83, "kp2": 84, "kp3": 85, "kp4": 86,
                "kp5": 87, "kp6": 88, "kp7": 89, "kp8": 91, "kp9": 92,
                "kp.": 65, "kp*": 67, "kp+": 69, "kp/": 75, "kp-": 78,
                "kpenter": 76, "kp=": 81,
            ]

            // Check special keys first
            if let keyCode = specialKeyMap[name] {
                return keyCode
            }

            // For single characters, use the keyboard layout-aware KeyMap
            // This properly handles non-QWERTY layouts
            if name.count == 1, let char = name.first {
                if let keyCode = KeyMap.shared[char] {
                    return CGKeyCode(keyCode)
                }
            }

            return nil
        }

        private func sendKey(keyCode: CGKeyCode, modifiers: CGEventFlags) async throws {
            guard let keyDown = CGEvent(keyboardEventSource: sharedEventSource, virtualKey: keyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: sharedEventSource, virtualKey: keyCode, keyDown: false) else {
                throw KeyError.eventCreationFailure
            }

            keyDown.flags = modifiers
            keyUp.flags = modifiers

            // Post to specific process instead of global tap
            keyDown.postToPid(pid)

            // Small delay between key down and key up
            try await Task.sleep(nanoseconds: 10_000_000)

            keyUp.postToPid(pid)

            // Sequoia workaround: post an extra event with cleared flags after key up
            if isSequoiaOrUp {
                keyUp.flags = []
                keyUp.postToPid(pid)
            }
        }

        private func sendCharacter(_ char: Character) throws {
            guard let keyDown = CGEvent(keyboardEventSource: sharedEventSource, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: sharedEventSource, virtualKey: 0, keyDown: false) else {
                throw KeyError.eventCreationFailure
            }

            var unicodeChar = Array(String(char).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)

            // Post to specific process instead of global tap
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)

            // Sequoia workaround
            if isSequoiaOrUp {
                keyUp.flags = []
                keyUp.postToPid(pid)
            }
        }

        private func printKeyList() {
            print("""
                AVAILABLE KEYS:

                Letters: a-z
                Numbers: 0-9

                Special Keys:
                  enter, return     - Return/Enter key
                  tab               - Tab key
                  space             - Space bar
                  delete, backspace - Delete/Backspace
                  escape, esc       - Escape key
                  forwarddelete     - Forward Delete

                Arrow Keys:
                  up, down, left, right

                Navigation:
                  home, end, pageup, pagedown

                Function Keys:
                  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

                Modifiers (combine with +):
                  cmd, command      - Command key (⌘)
                  ctrl, control     - Control key (⌃)
                  opt, option, alt  - Option key (⌥)
                  shift             - Shift key (⇧)

                Examples:
                  enter             - Press Enter
                  cmd+c             - Copy
                  cmd+v             - Paste
                  cmd+shift+s       - Save As
                  ctrl+alt+delete   - Ctrl+Alt+Delete
                """)
        }
    }
}

enum KeyError: Error, CustomStringConvertible {
    case unknownKey(String)
    case eventCreationFailure
    case activationTimeout

    var description: String {
        switch self {
        case .unknownKey(let key):
            return "Unknown key: '\(key)'. Use --list-keys to see available keys."
        case .eventCreationFailure:
            return "Failed to create key event"
        case .activationTimeout:
            return "Timed out waiting for application to activate"
        }
    }
}
