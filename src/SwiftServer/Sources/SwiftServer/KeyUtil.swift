import Carbon
import Foundation

enum KeyUtil {
    private static let keyCodeRange = 0..<127

    private static func transformKeyCode(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeUnretainedValue()
        let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayout = UnsafePointer<CoreServices.UCKeyboardLayout>.self
        let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(dataRef), to: keyLayout)
        let modifierKeyState = 0
        let keyTranslateOptions = OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit)
        var deadKeyState: UInt32 = 0
        let maxChars = 1
        var length = 0
        var chars = [UniChar](repeating: 0, count: maxChars)

        let error = CoreServices.UCKeyTranslate(keyLayoutPtr,
                                                keyCode,
                                                UInt16(CoreServices.kUCKeyActionDisplay),
                                                UInt32(modifierKeyState),
                                                UInt32(LMGetKbdType()),
                                                keyTranslateOptions,
                                                &deadKeyState,
                                                maxChars,
                                                &length,
                                                &chars)
        return error == noErr
            ? String(NSString(characters: &chars, length: length))
            : nil
    }
    
    static func stringToKeyCode(_ key: String) -> Int? {
        for code in keyCodeRange {
            if let str = transformKeyCode(UInt16(code)) {
                if str == key { return code }
            }
        }
        return nil
    }
}
