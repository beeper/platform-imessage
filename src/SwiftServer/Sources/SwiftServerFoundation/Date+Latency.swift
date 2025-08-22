import Foundation

public extension Date {
    var elapsedMilliseconds: Double {
        timeIntervalSinceNow * -1_000
    }
}
