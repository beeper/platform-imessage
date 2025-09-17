import AccessibilityControl
import CoreFoundation
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "ax-additions")

public extension Accessibility.Element {
    var isValid: Bool {
        (try? pid()) != nil
    }

    var isFrameValid: Bool {
        (try? self.frame()) != nil
    }

    var isInViewport: Bool {
        (try? self.frame()) != CGRect.null
    }

    // - breadth-first, seems faster than dfs
    // - default max complexity to 1,800; if i dump the complexity of the Messages app right now i get ~360. x10 that, should be plenty
    // - we can't turn `AXUIElement`s into e.g. `ObjectIdentifier`s and use that to track a set of seen elements and avoid cycles because
    //   the objects aren't pooled; any given instance of `AXUIElement` in memory is "transient" and another may take its place
    func recursiveChildren(maxTraversalComplexity: Int = 3_600) -> AnySequence<Accessibility.Element> {
        // incremented for every element with children that we discover; not "depth" since it's a running tally
        var traversalComplexity = 0

        return AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            guard traversalComplexity < maxTraversalComplexity else {
                log.error("HIT RECURSIVE TRAVERSAL COMPLEXITY LIMIT (\(traversalComplexity) > \(maxTraversalComplexity), queue count: \(queue.count)), terminating early")
                return nil
            }
            let elt = queue.removeFirst()
            if let children = try? elt.children() {
                defer { traversalComplexity += 1 }
                queue.append(contentsOf: children)
            }
            return elt
        })
    }

    func recursiveSelectedChildren() -> AnySequence<Accessibility.Element> {
        AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            let elt = queue.removeFirst()
            if let selectedChildren = try? elt.selectedChildren() {
                queue.append(contentsOf: selectedChildren)
            }
            return elt
        })
    }

    func recursivelyFindChild(withID id: String) -> Accessibility.Element? {
        recursiveChildren().lazy.first {
            (try? $0.identifier()) == id
        }
    }

    func setFrame(_ frame: CGRect) throws {
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            switch i {
            case 0:
                try? self.position(assign: frame.origin)
            case 1:
                try? self.size(assign: frame.size)
            default:
                break
            }
        }
    }

    func closeWindow() throws {
        guard let closeButton = try? self.windowCloseButton() else {
            throw ErrorMessage("window close button not found")
        }
        try closeButton.press()
    }
}

public extension Accessibility.Element {
    func firstChild(withRole role: KeyPath<AXRole.Type, String>) -> Accessibility.Element? {
        try? self.children().first { child in
            (try? child.role()) == AXRole.self[keyPath: role]
        }
    }
}
