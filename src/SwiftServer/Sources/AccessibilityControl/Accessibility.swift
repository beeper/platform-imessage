import Foundation
import ApplicationServices

public protocol AccessibilityConvertible {
    init?(axRaw: AnyObject)
    func axRaw() -> AnyObject?
}

private struct ConversionError: Error {}

extension Array: AccessibilityConvertible where Element: AccessibilityConvertible {
    public init?(axRaw: AnyObject) {
        guard let elements = axRaw as? [AnyObject] else { return nil }
        do {
            // fail if even one element initializer fails
            self = try elements.map {
                try Element(axRaw: $0).orThrow(ConversionError())
            }
        } catch { // ConversionError
            return nil
        }
    }
    public func axRaw() -> AnyObject? {
        try? map {
            try $0.axRaw().orThrow(ConversionError())
        } as AnyObject
    }
}

extension Dictionary: AccessibilityConvertible where Key == String, Value: AccessibilityConvertible {
    public init?(axRaw: AnyObject) {
        guard let elements = axRaw as? [String: AnyObject] else { return nil }
        do {
            self = try elements.mapValues {
                try Value(axRaw: $0).orThrow(ConversionError())
            }
        } catch {
            return nil
        }
    }
    public func axRaw() -> AnyObject? {
        try? mapValues {
            try $0.axRaw().orThrow(ConversionError())
        } as AnyObject
    }
}

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
    public struct Names {
        public typealias ActionName = Action.Name
        public typealias AttributeName<T> = Attribute<T>.Name
        public typealias MutableAttributeName<T> = MutableAttribute<T>.Name
        public typealias ParameterizedAttributeName<Parameter, Return> = ParameterizedAttribute<Parameter, Return>.Name

        init() {}
    }

    public static func isTrusted(shouldPrompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): shouldPrompt
        ] as CFDictionary)
    }

    static func check(_ code: AXError, file: StaticString = #fileID, line: UInt = #line) throws {
        guard code != .success else { return }
        throw AccessibilityError(code, file: file, line: line)
    }

    static func convertToAX<T>(_ value: T) -> AnyObject? {
        if let convertible = value as? AccessibilityConvertible {
            return convertible.axRaw()
        } else {
            return value as AnyObject
        }
    }

    static func convertFromAX<T>(_ value: AnyObject) -> T? {
        if let convertibleType = T.self as? AccessibilityConvertible.Type {
            return convertibleType.init(axRaw: value) as? T
        } else {
            return value as? T
        }
    }
}
