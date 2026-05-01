import AppKit
import IMessageCore

extension NSRunningApplication {
    func waitForLaunch(interval: TimeInterval = 0.05, timeout seconds: TimeInterval = 5) throws {
        let start = Date()
        while !self.isFinishedLaunching {
            Log.default.notice("sleeping \(interval)s for \(String(describing: self.localizedName)) to finish launching")
            Thread.sleep(forTimeInterval: interval)
            if self.isTerminated {
                throw ErrorMessage("\(String(describing: self.localizedName)) terminated")
            }
            if start.timeIntervalSinceNow < -seconds {
                Log.default.notice("assuming \(String(describing: self.localizedName)) has launched") // sometimes this gets stuck in an infinite loop
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

extension String {
    var containsLink: Bool {
        linkCount > 0
    }

    var linkCount: Int {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: self, options: [], range: NSRange(location: 0, length: utf16.count))
        return matches?.count ?? 0
    }
}
