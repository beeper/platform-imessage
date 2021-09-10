import Foundation
import ApplicationServices

extension Accessibility {
    public enum Struct: AccessibilityStructConvertible {
        case point(CGPoint)
        case size(CGSize)
        case rect(CGRect)
        case range(Range<Int>)
        case error(AccessibilityError)
        // case illegal -- represented by nil

        public var accessibilityStruct: Struct { self }

        public var kind: AXValueType {
            switch self {
            case .point: return .cgPoint
            case .size: return .cgSize
            case .rect: return .cgRect
            case .range: return .cfRange
            case .error: return .axError
            }
        }

        public func raw() -> AXValue? {
            switch self {
            case .point(var point):
                return AXValueCreate(kind, &point)
            case .size(var size):
                return AXValueCreate(kind, &size)
            case .rect(var rect):
                return AXValueCreate(kind, &rect)
            case .range(let range):
                var cfRange = CFRange(location: range.startIndex, length: range.count)
                return AXValueCreate(kind, &cfRange)
            case .error(let error):
                var code = error.code
                return AXValueCreate(kind, &code)
            }
        }

        init?(_ value: AXValue) {
            let kind = AXValueGetType(value)
            switch kind {
            case .illegal:
                return nil
            case .cgPoint:
                var point = CGPoint()
                AXValueGetValue(value, kind, &point)
                self = .point(point)
            case .cgSize:
                var size = CGSize()
                AXValueGetValue(value, kind, &size)
                self = .size(size)
            case .cgRect:
                var rect = CGRect()
                AXValueGetValue(value, kind, &rect)
                self = .rect(rect)
            case .cfRange:
                var range = CFRange()
                AXValueGetValue(value, kind, &range)
                self = .range(range.location..<(range.location + range.length))
            case .axError:
                var err: AXError = .success
                AXValueGetValue(value, kind, &err)
                self = .error(.init(err))
            @unknown default:
                return nil
            }
        }

        public init?(erased object: CFTypeRef) {
            guard CFGetTypeID(object) == AXValueGetTypeID() else {
                return nil
            }
            self.init(object as! AXValue)
        }
    }
}
