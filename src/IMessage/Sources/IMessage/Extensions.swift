import AppKit
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
    func waitForLaunch(interval: TimeInterval = 0.05, timeout seconds: TimeInterval = 5) async throws {
        let start = Date()
        while !self.isFinishedLaunching {
            Log.default.notice("sleeping \(interval)s for \(String(describing: self.localizedName)) to finish launching")
            try await Task.sleep(forTimeInterval: interval)
            if self.isTerminated {
                throw ErrorMessage("\(String(describing: self.localizedName)) terminated")
            }
            if start.timeIntervalSinceNow < -seconds {
                Log.default.notice("assuming \(String(describing: self.localizedName)) has launched") // sometimes this gets stuck in an infinite loop
                break
            }
        }
        try await Task.sleep(forTimeInterval: 0.01)
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
