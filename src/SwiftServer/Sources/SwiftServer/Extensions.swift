import AppKit

extension NSRunningApplication {
    func waitForLaunch(timeout seconds: TimeInterval = 5) throws {
        let start = Date()
        while !self.isFinishedLaunching {
            debugLog("sleeping 0.1s for \(self.localizedName) to finish launching")
            Thread.sleep(forTimeInterval: 0.1)
            if self.isTerminated {
                throw ErrorMessage("\(self.localizedName) terminated")
            }
            if start.timeIntervalSinceNow < -seconds {
                debugLog("assuming \(self.localizedName) has launched") // sometimes this gets stuck in an infinite loop
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
