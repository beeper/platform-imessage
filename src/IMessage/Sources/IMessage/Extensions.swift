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
    func waitForLaunch(timeout seconds: TimeInterval = 5) async throws {
        try Task.checkCancellation()
        guard !isTerminated else { throw launchTerminatedError() }
        if isFinishedLaunching {
            return
        }

        do {
            try await Task.withTimeout(seconds) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer {
                        group.cancelAll()
                    }

                    group.addTask { [self] in
                        try await self.waitForValue(\.isFinishedLaunching, true)
                    }

                    group.addTask { [self] in
                        try await self.waitForValue(\.isTerminated, true)
                        throw launchTerminatedError()
                    }

                    try await group.next()
                    guard !self.isTerminated else { throw launchTerminatedError() }
                }
            }
        } catch is Task<Never, Never>.TimeoutError {
            try Task.checkCancellation()
            guard !isTerminated else { throw launchTerminatedError() }
            Log.default.notice("assuming \(String(describing: localizedName)) has launched")
        }
    }
}

private func launchTerminatedError() -> ErrorMessage {
    ErrorMessage("Application terminated while waiting for launch")
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
