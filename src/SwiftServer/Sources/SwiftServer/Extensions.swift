import AppKit

extension NSRunningApplication {
    func waitForLaunch(interval: Double = 0.05, timeout seconds: TimeInterval = 5) throws {
        let start = Date()
        while !self.isFinishedLaunching {
            debugLog("sleeping \(interval)s for \(String(describing: self.localizedName)) to finish launching")
            Thread.sleep(forTimeInterval: interval)
            if self.isTerminated {
                throw ErrorMessage("\(String(describing: self.localizedName)) terminated")
            }
            if start.timeIntervalSinceNow < -seconds {
                debugLog("assuming \(String(describing: self.localizedName)) has launched") // sometimes this gets stuck in an infinite loop
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
