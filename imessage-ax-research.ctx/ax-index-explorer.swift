#!/usr/bin/env swift
// ax-index-explorer.swift
// Explores AXUIElement indexes in Messages.app transcript
// Run with: swift ax-index-explorer.swift

import Cocoa
import ApplicationServices

// MARK: - AX Helpers

func getAXValue(_ element: AXUIElement, attribute: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
}

func getAXChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let children = getAXValue(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
        return []
    }
    return children
}

func getAXRole(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: kAXRoleAttribute) as? String
}

func getAXRoleDescription(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: kAXRoleDescriptionAttribute) as? String
}

func getAXDescription(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: kAXDescriptionAttribute) as? String
}

func getAXIdentifier(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: "AXIdentifier") as? String
}

func getAXValue(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: kAXValueAttribute) as? String
}

func getAXTitle(_ element: AXUIElement) -> String? {
    return getAXValue(element, attribute: kAXTitleAttribute) as? String
}

func getAXFrame(_ element: AXUIElement) -> CGRect? {
    guard let posValue = getAXValue(element, attribute: kAXPositionAttribute),
          let sizeValue = getAXValue(element, attribute: kAXSizeAttribute) else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero

    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

    return CGRect(origin: position, size: size)
}

// Get all attribute names for an element
func getAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let result = AXUIElementCopyAttributeNames(element, &names)
    guard result == .success, let attributeNames = names as? [String] else {
        return []
    }
    return attributeNames
}

// MARK: - Messages App Discovery

func findMessagesApp() -> AXUIElement? {
    let apps = NSWorkspace.shared.runningApplications
    guard let messagesApp = apps.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) else {
        print("❌ Messages.app is not running")
        return nil
    }

    print("✅ Found Messages.app (PID: \(messagesApp.processIdentifier))")
    return AXUIElementCreateApplication(messagesApp.processIdentifier)
}

// MARK: - Element Discovery

struct MessageElement {
    let index: Int
    let element: AXUIElement
    let role: String
    let roleDescription: String?
    let identifier: String?
    let value: String?
    let description: String?
    let frame: CGRect?
    let depth: Int
    let path: [Int]  // Index path from root
}

func findElementsByRole(_ root: AXUIElement, targetRole: String, maxDepth: Int = 10) -> [AXUIElement] {
    var results: [AXUIElement] = []

    func search(_ element: AXUIElement, depth: Int) {
        guard depth < maxDepth else { return }

        if let role = getAXRole(element), role == targetRole {
            results.append(element)
        }

        for child in getAXChildren(element) {
            search(child, depth: depth + 1)
        }
    }

    search(root, depth: 0)
    return results
}

// Find transcript/scroll area containing messages
func findTranscriptArea(_ app: AXUIElement) -> AXUIElement? {
    // Look for the main window first
    guard let windows = getAXValue(app, attribute: kAXWindowsAttribute) as? [AXUIElement],
          let mainWindow = windows.first else {
        print("❌ No windows found")
        return nil
    }

    print("✅ Found main window")

    // Find scroll areas (transcript is typically in a scroll area)
    let scrollAreas = findElementsByRole(mainWindow, targetRole: "AXScrollArea")
    print("📜 Found \(scrollAreas.count) scroll areas")

    // The transcript scroll area is usually the largest one or has specific children
    for (i, scrollArea) in scrollAreas.enumerated() {
        let children = getAXChildren(scrollArea)
        let frame = getAXFrame(scrollArea)
        print("  ScrollArea \(i): \(children.count) children, frame: \(frame?.debugDescription ?? "none")")

        // Look for the one with the most children (likely the message list)
        // or specific identifiers
        if let identifier = getAXIdentifier(scrollArea) {
            print("    Identifier: \(identifier)")
        }
    }

    // Return the scroll area with the most children (heuristic for transcript)
    return scrollAreas.max(by: { getAXChildren($0).count < getAXChildren($1).count })
}

// MARK: - Message Enumeration

func enumerateMessages(_ transcriptArea: AXUIElement) -> [MessageElement] {
    var messages: [MessageElement] = []

    func enumerate(_ element: AXUIElement, depth: Int, path: [Int], parentIndex: Int) {
        let role = getAXRole(element) ?? "unknown"
        let roleDesc = getAXRoleDescription(element)

        // Collect elements that might be messages
        // Messages are typically: AXGroup, AXStaticText, or custom roles
        let isMessageCandidate = role == "AXGroup" ||
                                  role == "AXStaticText" ||
                                  role == "AXCell" ||
                                  role == "AXRow" ||
                                  roleDesc?.lowercased().contains("message") == true

        if isMessageCandidate && depth >= 2 {
            let msg = MessageElement(
                index: messages.count,
                element: element,
                role: role,
                roleDescription: roleDesc,
                identifier: getAXIdentifier(element),
                value: getAXValue(element),
                description: getAXDescription(element),
                frame: getAXFrame(element),
                depth: depth,
                path: path
            )
            messages.append(msg)
        }

        // Recurse into children
        let children = getAXChildren(element)
        for (i, child) in children.enumerated() {
            enumerate(child, depth: depth + 1, path: path + [i], parentIndex: i)
        }
    }

    enumerate(transcriptArea, depth: 0, path: [], parentIndex: 0)
    return messages
}

// MARK: - Detailed Element Inspection

func inspectElement(_ element: AXUIElement, label: String) {
    print("\n🔍 Inspecting: \(label)")
    print("   All attributes:")

    let attributes = getAttributeNames(element)
    for attr in attributes.sorted() {
        if let value = getAXValue(element, attribute: attr) {
            let valueStr = String(describing: value).prefix(100)
            print("     \(attr): \(valueStr)")
        }
    }
}

// MARK: - Find Messages by Text Content

func findMessagesByContent(_ app: AXUIElement) {
    print("\n📨 Searching for text content in Messages...")

    guard let transcript = findTranscriptArea(app) else {
        print("❌ Could not find transcript area")
        return
    }

    // Find all static text elements (message bubbles contain text)
    let textElements = findElementsByRole(transcript, targetRole: "AXStaticText", maxDepth: 15)
    print("Found \(textElements.count) text elements\n")

    print("=" .repeating(80))
    print("INDEX | Y-POS  | TEXT (first 60 chars)")
    print("=" .repeating(80))

    // Sort by Y position (top to bottom = oldest to newest typically)
    let sortedTexts = textElements.enumerated().map { (index: $0, element: $1) }
        .sorted {
            (getAXFrame($0.element)?.minY ?? 0) < (getAXFrame($1.element)?.minY ?? 0)
        }

    for (sortedIndex, item) in sortedTexts.enumerated() {
        let frame = getAXFrame(item.element)
        let value = getAXValue(item.element) ?? getAXDescription(item.element) ?? "(no text)"
        let truncated = String(value.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
        let yPos = frame?.minY ?? 0

        print(String(format: "%5d | %6.0f | %@", sortedIndex, yPos, truncated))
    }
}

// MARK: - Explore Hierarchy

func exploreHierarchy(_ app: AXUIElement, maxElements: Int = 50) {
    print("\n🌳 Exploring Messages hierarchy (first \(maxElements) elements)...\n")

    var count = 0

    func explore(_ element: AXUIElement, depth: Int, indexPath: [Int]) {
        guard count < maxElements else { return }
        count += 1

        let indent = String(repeating: "  ", count: depth)
        let role = getAXRole(element) ?? "?"
        let roleDesc = getAXRoleDescription(element)
        let identifier = getAXIdentifier(element)
        let value = getAXValue(element)
        let desc = getAXDescription(element)

        var info = "\(indent)[\(indexPath.map(String.init).joined(separator: "."))] \(role)"

        if let rd = roleDesc { info += " (\(rd))" }
        if let id = identifier { info += " id='\(id)'" }
        if let v = value?.prefix(40) { info += " val='\(v)'" }
        if let d = desc?.prefix(40) { info += " desc='\(d)'" }

        print(info)

        let children = getAXChildren(element)
        for (i, child) in children.enumerated() {
            explore(child, depth: depth + 1, indexPath: indexPath + [i])
        }
    }

    // Try multiple ways to get windows
    var windows: [AXUIElement] = []

    if let w = getAXValue(app, attribute: kAXWindowsAttribute) as? [AXUIElement] {
        windows = w
    }

    if windows.isEmpty {
        // Try focused window
        if let focused = getAXValue(app, attribute: kAXFocusedWindowAttribute) as AnyObject? {
            windows = [focused as! AXUIElement]
        }
    }

    if windows.isEmpty {
        // Try main window
        if let main = getAXValue(app, attribute: kAXMainWindowAttribute) as AnyObject? {
            windows = [main as! AXUIElement]
        }
    }

    if windows.isEmpty {
        print("⚠️  No windows found!")
        print("   Make sure Messages.app has a visible window with a conversation open.")
        print("   (Not minimized to dock)")
        print("\n   Exploring app element for debugging...")
        explore(app, depth: 0, indexPath: [0])
        return
    }

    print("Found \(windows.count) window(s)")
    for (i, window) in windows.enumerated() {
        print("\n--- Window \(i) ---")
        explore(window, depth: 0, indexPath: [i])
    }
}

// MARK: - Find Cells/Rows (Collection View items)

func findCellsWithIndexes(_ app: AXUIElement) {
    print("\n📋 Finding cells/rows with their indexes...\n")

    guard let windows = getAXValue(app, attribute: kAXWindowsAttribute) as? [AXUIElement],
          let mainWindow = windows.first else {
        print("No windows")
        return
    }

    // Find all cells (collection view items)
    let cells = findElementsByRole(mainWindow, targetRole: "AXCell", maxDepth: 20)
    let groups = findElementsByRole(mainWindow, targetRole: "AXGroup", maxDepth: 20)
    let rows = findElementsByRole(mainWindow, targetRole: "AXRow", maxDepth: 20)

    print("Found: \(cells.count) cells, \(groups.count) groups, \(rows.count) rows")

    // Look at cells - these might be message bubbles
    print("\n--- CELLS (likely message bubbles) ---")
    for (i, cell) in cells.prefix(20).enumerated() {
        let frame = getAXFrame(cell)
        let identifier = getAXIdentifier(cell)
        let desc = getAXDescription(cell)
        let children = getAXChildren(cell)

        // Try to get the index from AXIndex attribute
        let indexAttr = getAXValue(cell, attribute: "AXIndex")

        print("Cell \(i):")
        print("  Y: \(frame?.minY ?? 0), Height: \(frame?.height ?? 0)")
        print("  Identifier: \(identifier ?? "none")")
        print("  Description: \(desc?.prefix(50) ?? "none")")
        print("  AXIndex: \(indexAttr ?? "none" as AnyObject)")
        print("  Children: \(children.count)")

        // Get text content from children
        for child in children {
            if getAXRole(child) == "AXStaticText" {
                if let text = getAXValue(child) {
                    print("  Text: \(text.prefix(50))")
                }
            }
        }
        print()
    }
}

// MARK: - Main

func main() {
    print("🔬 AX Index Explorer for Messages.app")
    print("=====================================\n")

    // Check accessibility permissions
    let trusted = AXIsProcessTrusted()
    print("Accessibility trusted: \(trusted)")
    if !trusted {
        print("⚠️  Please grant accessibility permissions in System Preferences")
        print("   Security & Privacy → Privacy → Accessibility")
        return
    }

    guard let app = findMessagesApp() else {
        return
    }

    // Run different exploration modes based on command line arg
    let args = CommandLine.arguments
    let mode = args.count > 1 ? args[1] : "all"

    switch mode {
    case "hierarchy":
        exploreHierarchy(app, maxElements: 100)
    case "cells":
        findCellsWithIndexes(app)
    case "text":
        findMessagesByContent(app)
    case "all":
        exploreHierarchy(app, maxElements: 30)
        findCellsWithIndexes(app)
        findMessagesByContent(app)
    default:
        print("Usage: swift ax-index-explorer.swift [hierarchy|cells|text|all]")
    }

    print("\n✅ Done!")
}

extension String {
    func repeating(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}

main()
