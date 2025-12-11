import AppKit
import Combine
import SwiftServerFoundation

extension NSRunningApplication {
    // ???: (@skip) - why are we polling and using `Thread.sleep` here?
    // FIXME: (@pmanot) - Replace polling with observation
    func _legacyWaitForLaunch(interval: TimeInterval = 0.05, timeout seconds: TimeInterval = 5) throws {
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
    
    func waitForLaunch(timeout seconds: TimeInterval = 8) async throws {
        var token: AnyCancellable? = nil
        
        defer { token?.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            token = self.publisher(for: \.isFinishedLaunching)
                .timeout(.seconds(seconds), scheduler: RunLoop.main)
                .sink { completion in
                    if self.isFinishedLaunching {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ErrorMessage("\(String(describing: self.localizedName)) did not launch in \(seconds) seconds"))
                    }
                } receiveValue: { value in
                    if value {
                        assert(self.isFinishedLaunching, "fatal error: value should always be the same as `isFinishedLaunching`")
                        continuation.resume()
                    }
                }
            
            if self.isFinishedLaunching {
                continuation.resume()
            }
        }
    }
}
