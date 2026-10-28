import AppKit
import ApplicationServices
import Testing

struct MessagesDockSnapshot {
    let tiles: Int
    let running: Int
}

@MainActor
func messagesDockSnapshot() throws -> MessagesDockSnapshot {
    let states = try messagesDockRunningStates()
    return MessagesDockSnapshot(tiles: states.count, running: states.filter { $0 }.count)
}

// Inspect only Messages tiles; never log other Dock apps, titles, or badge values.
@MainActor
private func messagesDockRunningStates() throws -> [Bool] {
    try #require(AXIsProcessTrusted(), "Dock inspection requires Accessibility permission")
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
    try #require(attribute(root, kAXChildrenAttribute as CFString) != nil, "Dock AX tree is unavailable")
    let maximumDepth = 5
    func states(_ element: AXUIElement, depth: Int) throws -> [Bool] {
        guard depth <= maximumDepth else { return [] }
        let url = attribute(element, kAXURLAttribute as CFString) as? URL
        let matched = url?.path == "/System/Applications/Messages.app"
        let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        var result: [Bool] = []
        if matched {
            result.append(try #require(attribute(element, "AXIsApplicationRunning" as CFString) as? Bool))
        }
        for child in children { result += try states(child, depth: depth + 1) }
        return result
    }
    return try states(root, depth: 0)
}
