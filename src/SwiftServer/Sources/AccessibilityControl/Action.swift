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

        init(element: Element, name: Name) {
            self.element = element
            self.name = name
        }

        public var description: String {
            var description: CFString?
            guard (try? check(AXUIElementCopyActionDescription(element.raw, name.value as CFString, &description))) != nil,
                  let ret = description as String?
            else { return "[invalid action] \(element.raw): \(name.value)" }
            return ret
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
