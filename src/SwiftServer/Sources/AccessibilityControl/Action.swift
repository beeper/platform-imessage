import Foundation
import ApplicationServices

extension Accessibility {
    public final class Action: CustomStringConvertible {
        public struct Name: AccessibilityPhantomName {
            public let value: String
            public init(_ value: String) {
                self.value = value
            }
        }

        public let element: Element
        public let name: Name

        private var cachedDescription: String?

        private init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }

        private func cacheDescription() throws {
            var description: CFString?
            try check(AXUIElementCopyActionDescription(element.raw, name.value as CFString, &description))
            let ret = description as String?
            cachedDescription = ret
            if description == nil {
                throw AccessibilityError(.actionUnsupported)
            }
        }

        // Doesn't check for existence. Stuff might fail unexpectedly
        // if the action doesn't actually exist on the element.
        static func unsafeCreate(element: Element, name: Name) -> Action {
            Action(element: element, name: name)
        }

        // this version of create verifies that the action actually
        // exists by copying its description off of the element
        static func create(element: Element, name: Name) throws -> Action {
            let elt = Action(element: element, name: name)
            try elt.cacheDescription()
            return elt
        }

        public var description: String {
            if let cached = cachedDescription {
                return cached
            }
            try? cacheDescription()
            return cachedDescription ?? "\(element.raw): \(name.value)"
        }

        public func callAsFunction(
            file: StaticString = #fileID,
            line: UInt = #line
        ) throws {
            try check(
                AXUIElementPerformAction(element.raw, name.value as CFString),
                file: file,
                line: line
            )
        }
    }
}
