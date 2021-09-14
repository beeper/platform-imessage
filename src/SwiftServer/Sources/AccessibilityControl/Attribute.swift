import Foundation
import ApplicationServices

public protocol AttributeProtocol: CustomStringConvertible {
    associatedtype Name: AccessibilityPhantomName
    associatedtype Value

    var element: Accessibility.Element { get }
    var name: Name { get }
}

extension AttributeProtocol {
    public var description: String {
        "\(element): \(name)"
    }

    public func isSettable(file: StaticString = #fileID, line: UInt = #line) throws -> Bool {
        var isSettable: DarwinBoolean = false
        try Accessibility.check(
            AXUIElementIsAttributeSettable(element.raw, name.value as CFString, &isSettable),
            file: file, line: line
        )
        return isSettable.boolValue
    }

    public func callAsFunction(file: StaticString = #fileID, line: UInt = #line) throws -> Value {
        var val: AnyObject?
        try Accessibility.check(
            AXUIElementCopyAttributeValue(element.raw, name.value as CFString, &val),
            file: file, line: line
        )
        if let val = val.flatMap(Accessibility.convertFromAX) as Value? {
            return val
        } else {
            throw AccessibilityError(.failure, file: file, line: line)
        }
    }
}

extension Accessibility {
    public typealias AnyAttribute = Attribute<Any>

    public final class Attribute<Value>: AttributeProtocol {
        public struct Name: AccessibilityPhantomName {
            public let value: String
            public init(_ value: String) {
                self.value = value
            }
        }

        public let element: Element
        public let name: Name

        init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }
    }

    public final class MutableAttribute<Value>: AttributeProtocol {
        public struct Name: AccessibilityPhantomName {
            public let value: String
            public init(_ value: String) {
                self.value = value
            }
        }

        public let element: Element
        public let name: Name

        init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }

        public func callAsFunction(assign value: Value, file: StaticString = #fileID, line: UInt = #line) throws {
            guard let raw = convertToAX(value) else {
                throw AccessibilityError(.failure, file: file, line: line)
            }
            try check(
                AXUIElementSetAttributeValue(element.raw, name.value as CFString, raw),
                file: file, line: line
            )
        }
    }

    public final class ParameterizedAttribute<Parameter, Return>: CustomStringConvertible {
        public struct Name: AccessibilityPhantomName {
            public let value: String
            public init(_ value: String) {
                self.value = value
            }
        }

        public let element: Element
        public let name: Name

        public var description: String {
            "\(element): \(name)"
        }

        init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }

        public func callAsFunction(_ value: Parameter, file: StaticString = #fileID, line: UInt = #line) throws -> Return {
            guard let rawValue = convertToAX(value) else {
                throw AccessibilityError(.failure, file: file, line: line)
            }
            var result: AnyObject?
            try check(AXUIElementCopyParameterizedAttributeValue(element.raw, name.value as CFString, rawValue, &result))
            if let result = result.flatMap(convertFromAX) as Return? {
                return result
            } else {
                throw AccessibilityError(.failure, file: file, line: line)
            }
        }
    }
}

// just `Collection` would make this applicable to dictionaries as well
extension AttributeProtocol where Value: RandomAccessCollection {
    func arrayCount() throws -> Int {
        var count: CFIndex = 0
        try Accessibility.check(AXUIElementGetAttributeValueCount(element.raw, name.value as CFString, &count))
        return count
    }

    func arrayGet(range: Range<Int>, file: StaticString = #fileID, line: UInt = #line) throws -> [Value.Element] {
        var values: CFArray?
        try Accessibility.check(
            AXUIElementCopyAttributeValues(element.raw, name.value as CFString, range.startIndex, range.count, &values)
        )
        guard let values = values.flatMap(Accessibility.convertFromAX) as [Value.Element]? else {
            throw AccessibilityError(.failure, file: file, line: line)
        }
        return values
    }
}
