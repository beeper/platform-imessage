import Foundation

struct BridgedDisplaySpace {
    let identifier: String
    let space: UInt64
    let bounds: CGRect

    static func destination(preferredDisplay: String?, windowFrame: CGRect, displays: [Self]) -> Self? {
        if let preferredDisplay, let remembered = displays.first(where: { $0.identifier == preferredDisplay }) {
            return remembered
        }
        // A disconnected display has no destination. Use the surviving display
        // containing most of the relocated window, rather than a global Space ID.
        return displays.max { left, right in
            let leftIntersection = left.bounds.intersection(windowFrame)
            let rightIntersection = right.bounds.intersection(windowFrame)
            let leftArea = leftIntersection.isNull ? 0 : leftIntersection.width * leftIntersection.height
            let rightArea = rightIntersection.isNull ? 0 : rightIntersection.width * rightIntersection.height
            return leftArea < rightArea
        }
    }
}

