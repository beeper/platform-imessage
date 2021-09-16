import Foundation
import ApplicationServices

extension Accessibility {
    @dynamicMemberLookup
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
        public func hitTest(x: Float, y: Float) throws -> Element {
            var res: AXUIElement?
            try check(AXUIElementCopyElementAtPosition(raw, x, y, &res))
            return try Element(raw: res.orThrow(AccessibilityError(.noValue)))
        }

        public func supportedActions() throws -> [Action] {
            var actions: CFArray?
            try check(AXUIElementCopyActionNames(raw, &actions))
            guard let names = actions as? [String] else { return [] }
            return names
                .map(Action.Name.init)
                .map { Action(element: self, name: $0) }
        }

        public func action(_ name: Action.Name) -> Action {
            Action(element: self, name: name)
        }

        public subscript(dynamicMember actionName: KeyPath<Names, Action.Name>) -> Action {
            self.action(Names()[keyPath: actionName])
        }

        public func supportedAttributes() throws -> [Attribute<Any>] {
            var rawNames: CFArray?
            try check(AXUIElementCopyAttributeNames(raw, &rawNames))
            guard let names = rawNames as? [String] else { return [] }
            return names
                .map(Attribute<Any>.Name.init(_:))
                .map { Attribute(element: self, name: $0) }
        }

        public func attribute<T>(_ name: Attribute<T>.Name) -> Attribute<T> {
            Attribute(element: self, name: name)
        }

        public subscript<T>(dynamicMember attributeName: KeyPath<Names, Attribute<T>.Name>) -> Attribute<T> {
            attribute(Names()[keyPath: attributeName])
        }

        public func mutableAttribute<T>(_ name: MutableAttribute<T>.Name) -> MutableAttribute<T> {
            MutableAttribute(element: self, name: name)
        }

        public subscript<T>(dynamicMember attributeName: KeyPath<Names, MutableAttribute<T>.Name>) -> MutableAttribute<T> {
            mutableAttribute(Names()[keyPath: attributeName])
        }

        public func supportedParameterizedAttributes() throws -> [ParameterizedAttribute<Any, Any>] {
            var rawNames: CFArray?
            try check(AXUIElementCopyParameterizedAttributeNames(raw, &rawNames))
            guard let names = rawNames as? [String] else { return [] }
            return names
                .map(ParameterizedAttribute<Any, Any>.Name.init)
                .map { .init(element: self, name: $0) }
        }

        public func parameterizedAttribute<Parameter, Return>(
            _ name: ParameterizedAttribute<Parameter, Return>.Name
        ) -> ParameterizedAttribute<Parameter, Return> {
            .init(element: self, name: name)
        }

        public subscript<Parameter, Return>(
            dynamicMember attributeName: KeyPath<Names, ParameterizedAttribute<Parameter, Return>.Name>
        ) -> ParameterizedAttribute<Parameter, Return> {
            parameterizedAttribute(Names()[keyPath: attributeName])
        }

        // nil: reset
        public func setMessagingTimeout(_ timeout: Float?) throws {
            try check(AXUIElementSetMessagingTimeout(raw, timeout ?? 0))
        }
    }
}

extension Accessibility.Element: AccessibilityConvertible {
    public func axRaw() -> AnyObject? {
        raw
    }
    public convenience init?(axRaw: AnyObject) {
        self.init(erased: axRaw)
    }
}
