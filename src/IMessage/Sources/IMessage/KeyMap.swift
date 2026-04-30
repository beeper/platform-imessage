import Carbon
import Foundation

// not thread-safe
final class KeyMap {
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
                    /* modifierKeyState: */ 0,
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
