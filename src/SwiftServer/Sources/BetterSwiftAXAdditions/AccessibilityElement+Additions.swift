import AccessibilityControl
import CoreFoundation
import SwiftServerFoundation

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

    // breadth-first, seems faster than dfs
    func recursiveChildren() -> AnySequence<Accessibility.Element> {
        AnySequence(sequence(state: [self]) { queue -> Accessibility.Element? in
            guard !queue.isEmpty else { return nil }
            let elt = queue.removeFirst()
            if let children = try? elt.children() {
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
