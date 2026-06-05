import AppKit
import Combine
import IMessageCore

extension NSApplication {
    @MainActor
    package func prepareAndActivate() {
        setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

extension NSRunningApplication {
    func waitForLaunch(timeout seconds: TimeInterval = 5) async throws {
        if isFinishedLaunching, !isTerminated {
            return
        }

        try await withTimeout(seconds) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer {
                    group.cancelAll()
                }

                group.addTask { [self] in
                    try await self.waitForValue(\.isFinishedLaunching, true)
                }

                group.addTask { [self] in
                    try await self.waitForValue(\.isTerminated, true)
                    throw ErrorMessage("Application terminated while waiting for launch")
                }

                try await group.next()
            }
        }
    }
}

private extension NSDataDetector {
    static let linkDetector: NSDataDetector? = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            Log.default.error("failed to create link data detector", error: error)
            return nil
        }
    }()
}

extension String {
    var containsLink: Bool {
        let match = NSDataDetector.linkDetector?.firstMatch(in: self, options: [], range: NSRange(location: 0, length: utf16.count))

        return match != nil
    }

    var linkCount: Int {
        NSDataDetector.linkDetector?.numberOfMatches(in: self, options: [], range: NSRange(location: 0, length: utf16.count)) ?? 0
    }
}

extension NSRect {
    /// Converts a rect between Cocoa coordinates (origin at the bottom-left of the
    /// primary display) and screen/AX coordinates (origin at the top-left of the
    /// primary display, the space used by Accessibility window positions and
    /// CGWindow bounds). The flip is about the primary display's height, so it is
    /// its own inverse and is correct regardless of which display the rect is on.
    @MainActor
    func flippedBetweenCocoaAndScreenSpace() -> NSRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return self }
        return NSRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
