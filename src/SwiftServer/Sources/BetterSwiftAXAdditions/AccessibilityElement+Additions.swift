import AccessibilityControl
import ApplicationServices
import CoreFoundation
import SwiftServerFoundation
import Logging
import Collections

private let log = Logger(swiftServerLabel: "ax-additions")

extension Accessibility.Element: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }
}

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
    // - default max complexity to 3,600; if i dump the complexity of the Messages app right now i get ~360. x10 that, should be plenty
    // - tracks visited elements via CFEqual/CFHash to avoid cycles
    //   (ObjectIdentifier won't work because AXUIElement instances are transient and not pooled)
    func recursiveChildren(maxTraversalComplexity: Int = 3_600) -> AnySequence<Accessibility.Element> {
        // incremented for every element with children that we discover; not "depth" since it's a running tally
        var traversalComplexity = 0
        var visited = Set<Accessibility.Element>()

        return AnySequence(sequence(state: [self] as Deque) { queue -> Accessibility.Element? in
            while true {
                guard traversalComplexity < maxTraversalComplexity else {
                    log.error("HIT RECURSIVE TRAVERSAL COMPLEXITY LIMIT (\(traversalComplexity) > \(maxTraversalComplexity), queue count: \(queue.count)), terminating early")
                    return nil
                }

                guard let element = queue.popFirst() else {
                    // queue is empty, we're done
                    return nil
                }

                // Skip already-visited elements (cycle detection)
                guard visited.insert(element).inserted else {
                    continue
                }

                if let children = try? element.children() {
                    defer { traversalComplexity += 1 }
                    queue.append(contentsOf: children)
                }
                return element
            }
        })
    }

    func recursiveSelectedChildren() -> AnySequence<Accessibility.Element> {
        var visited = Set<Accessibility.Element>()

        return AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            while true {
                guard !queue.isEmpty else { return nil }
                let elt = queue.removeFirst()

                // Skip already-visited elements (cycle detection)
                guard visited.insert(elt).inserted else {
                    continue
                }

                if let selectedChildren = try? elt.selectedChildren() {
                    queue.append(contentsOf: selectedChildren)
                }
                return elt
            }
        })
    }

    func recursivelyFindChild(withID id: String) -> Accessibility.Element? {
        // Try fast path using copyHierarchy (single IPC call with identifier prefetched)
        if let hierarchy = copyHierarchy(attributes: [.identifier, .children]) {
            return hierarchy.first { (try? $0.identifier()) == id }
        }
        // Fallback to manual traversal
        return recursiveChildren().lazy.first { (try? $0.identifier()) == id }
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
