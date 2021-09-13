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
    public let file: StaticString
    public let line: UInt

    public init(_ code: AXError, file: StaticString = #fileID, line: UInt = #line) {
        self.code = code
        self.file = file
        self.line = line
    }

    private var codeName: String {
        switch code {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown"
        }
    }

    public var description: String {
        "AXError: \(codeName) (\(code.rawValue)) at \(file):\(line)"
    }
}

public enum Accessibility {
    public static func isTrusted(shouldPrompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): shouldPrompt
        ] as CFDictionary)
    }

    static func check(_ code: AXError, file: StaticString = #fileID, line: UInt = #line) throws {
        guard code != .success else { return }
        throw AccessibilityError(code, file: file, line: line)
    }
}
