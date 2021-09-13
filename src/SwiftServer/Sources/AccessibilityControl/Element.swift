import Foundation
import ApplicationServices

extension Accessibility {
    public final class Element: CustomStringConvertible {
        public let raw: AXUIElement

        public var description: String { "\(raw)" }

        public init(raw: AXUIElement) {
            self.raw = raw
        }

        public convenience init?(erased object: CFTypeRef) {
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            self.init(raw: object as! AXUIElement)
        }

        public init(pid: pid_t) {
            raw = AXUIElementCreateApplication(pid)
        }

        public static let systemWide = Element(raw: AXUIElementCreateSystemWide())

        public func pid() throws -> pid_t {
            var pid: pid_t = 0
            try check(AXUIElementGetPid(raw, &pid))
            return pid
        }

        // point in screen coordinates
        // element must represent an app or .systemWide
        public func hitTest(x: Float, y: Float) throws -> Element? {
            var optRes: AXUIElement?
            do {
                try check(AXUIElementCopyElementAtPosition(raw, x, y, &optRes))
            } catch let error as AccessibilityError where error.code == .noValue {
                return nil
            }
            guard let res = optRes else { return nil }
            return Element(raw: res)
        }

        public func supportedActions() throws -> [Action] {
            var actions: CFArray?
            try check(AXUIElementCopyActionNames(raw, &actions))
            guard let names = actions as? [String] else { return [] }
            return names.map(Action.Name.init).map {
                Action.unsafeCreate(element: self, name: $0)
            }
        }

        public func actionDescriptor(_ name: Action.Name) throws -> Action? {
            do {
                return try Action.create(element: self, name: name)
            } catch let error as AccessibilityError where error.code == .actionUnsupported {
                return nil
            }
        }

        public func perform(
            action name: Action.Name,
            file: StaticString = #fileID,
            line: UInt = #line
        ) throws {
            try Action.create(element: self, name: name)(file: file, line: line)
        }

        public func supportedAttributes() throws -> [Attribute] {
            var rawNames: CFArray?
            try check(AXUIElementCopyAttributeNames(raw, &rawNames))
            guard let names = rawNames as? [String] else { return [] }
            return names.map { Attribute.unsafeCreate(element: self, name: .init($0)) }
        }

        public func attributeDescriptor(_ name: Attribute.Name) throws -> Attribute? {
            do {
                return try Attribute.create(element: self, name: name)
            } catch let error as AccessibilityError where error.code == .attributeUnsupported {
                return nil
            }
        }

        public func attribute(
            _ name: Attribute.Name,
            file: StaticString = #fileID,
            line: UInt = #line
        ) throws -> AnyObject {
            try Attribute.create(element: self, name: name).get(file: file, line: line)
        }

        public func setAttribute(
            _ name: Attribute.Name,
            to value: AnyObject,
            file: StaticString = #fileID,
            line: UInt = #line
        ) throws {
            try Attribute.create(element: self, name: name).set(value, file: file, line: line)
        }

        public func supportedParameterizedAttributes() throws -> [ParameterizedAttributeName] {
            var rawNames: CFArray?
            try check(AXUIElementCopyParameterizedAttributeNames(raw, &rawNames))
            guard let names = rawNames as? [String] else { return [] }
            return names.map(ParameterizedAttributeName.init)
        }

        public func parameterizedAttribute(_ name: ParameterizedAttributeName, with parameter: AnyObject) throws -> AnyObject {
            var result: AnyObject?
            try check(AXUIElementCopyParameterizedAttributeValue(raw, name.value as CFString, parameter, &result))
            if let result = result {
                return result
            } else {
                throw AccessibilityError(.failure)
            }
        }

        // nil: reset
        public func setMessagingTimeout(_ timeout: Float?) throws {
            try check(AXUIElementSetMessagingTimeout(raw, timeout ?? 0))
        }
    }
}
