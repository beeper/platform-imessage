import Foundation
import ApplicationServices

public protocol AccessibilityStructConvertible {
    var accessibilityStruct: Accessibility.Struct { get }
}
//extension CGPoint: AccessibilityStructConvertible {
//    public var accessibilityStruct: Accessibility.Struct { .point(self) }
//}
//extension CGSize: AccessibilityStructConvertible {
//    public var accessibilityStruct: Accessibility.Struct { .size(self) }
//}
//extension CGRect: AccessibilityStructConvertible {
//    public var accessibilityStruct: Accessibility.Struct { .rect(self) }
//}
//extension Range: AccessibilityStructConvertible where Bound == Int {
//    public var accessibilityStruct: Accessibility.Struct { .range(self) }
//}
//extension AccessibilityError: AccessibilityStructConvertible {
//    public var accessibilityStruct: Accessibility.Struct { .error(self) }
//}

public protocol AccessibilityPhantomName: LosslessStringConvertible, ExpressibleByStringLiteral {
    var value: String { get }
    init(_ value: String)
}

extension AccessibilityPhantomName {
    public var description: String { value }
    public init(_ cfString: CFString) {
        self.init(cfString as String)
    }
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

public struct AccessibilityError: Error, CustomStringConvertible {
    public let code: AXError
    public init(_ code: AXError) {
        self.code = code
    }

    public var description: String {
        "AXError: \(code.rawValue)"
    }
}

public enum Accessibility {
    public static func isTrusted(shouldPrompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): shouldPrompt
        ] as CFDictionary)
    }

    static func check(_ code: AXError) throws {
        guard code != .success else { return }
        throw AccessibilityError(code)
    }
}
