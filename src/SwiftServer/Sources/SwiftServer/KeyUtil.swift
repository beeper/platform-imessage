import Carbon
import Foundation

enum KeyUtil {
    private static let keyCodeRange = 0..<127

    // based off
    // https://github.com/search?l=Swift&q=UCKeyTranslate&type=Code
    // https://github.com/techrisdev/Snap/blob/main/Snap/Keyboard%20Shortcuts/Key.swift
    // https://stackoverflow.com/a/35138823 
    // https://gist.github.com/ArthurYidi/3af4ccd7edc87739530476fc80a22e12
    // https://github.com/timbertson/Slinger.app/blob/master/src/Keybinding.swift
    private static func transformKeyCode(_ keyCode: UInt16) -> Character? {
        var keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        var layoutDataPointer = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData) 
        if layoutDataPointer == nil {
            keyboard = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            layoutDataPointer = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData)
        }
        guard let layoutDataPointer = layoutDataPointer else {
            debugLog("transformKeyCode: Failed to get layout data")
            return nil
        }
        var stringLength = 0
        let maxChars = 1
        var deadKeyState: UInt32 = 0
        let keyTranslateOptions: UInt32 = 0
        let modifierKeyState: UInt32 = 0
        var unicodeString = [UniChar](repeating: 0, count: maxChars)
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        let status = layoutData.withUnsafeBytes {
            UCKeyTranslate($0.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                           keyCode,
                           UInt16(kUCKeyActionDown),
                           modifierKeyState,
                           UInt32(LMGetKbdType()),
                           keyTranslateOptions,
                           &deadKeyState,
                           maxChars,
                           &stringLength,
                           &unicodeString)
        }

        return status == noErr
            ? [Character](String(NSString(characters: unicodeString, length: stringLength)))[0]
            : nil
    }
    
    static func stringToKeyCode(_ key: Character) -> Int? {
        for code in keyCodeRange {
            if let str = transformKeyCode(UInt16(code)) {
                if str == key { return code }
            }
        }
        return nil
    }
}
