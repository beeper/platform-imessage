import Foundation
import ApplicationServices

extension Accessibility {
    public final class Attribute: CustomStringConvertible {
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

        private var cachedIsSettable: Bool?
        public var isSettable: Bool {
            if let cached = cachedIsSettable {
                return cached
            }
            try? cacheIsSettable()
            return cachedIsSettable ?? false
        }

        private init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }

        private func cacheIsSettable() throws {
            cachedIsSettable = false
            // FIXME: this sometimes returns .failure, wat
//            var isSettable: DarwinBoolean = false
//            // conveniently, throws if the attribute doesn't exist
//            try check(AXUIElementIsAttributeSettable(element.raw, name.value as CFString, &isSettable))
//            cachedIsSettable = isSettable.boolValue
        }

        static func unsafeCreate(element: Element, name: Name) -> Attribute {
            Attribute(element: element, name: name)
        }

        static func create(element: Element, name: Name) throws -> Attribute {
            let ret = Attribute(element: element, name: name)
            try ret.cacheIsSettable()
            return ret
        }

        public func get() throws -> AnyObject {
            var val: AnyObject?
            try check(AXUIElementCopyAttributeValue(element.raw, name.value as CFString, &val))
            if let val = val {
                return val
            } else {
                throw AccessibilityError(.attributeUnsupported)
            }
        }

        public func set(_ value: AnyObject) throws {
            try check(AXUIElementSetAttributeValue(element.raw, name.value as CFString, value))
        }

        public func arrayCount() throws -> Int {
            var count: CFIndex = 0
            try check(AXUIElementGetAttributeValueCount(element.raw, name.value as CFString, &count))
            return count
        }

        public func getArray(range: Range<Int>) throws -> [AnyObject] {
            var values: CFArray?
            try check(AXUIElementCopyAttributeValues(element.raw, name.value as CFString, range.startIndex, range.count, &values))
            return (values as [AnyObject]?) ?? []
        }
    }

    public struct ParameterizedAttributeName: AccessibilityPhantomName {
        public let value: String
        public init(_ value: String) {
            self.value = value
        }
    }
}
