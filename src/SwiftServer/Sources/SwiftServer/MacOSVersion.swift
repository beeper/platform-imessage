import Foundation

public enum MacOSVersion: Int, CaseIterable {
    case monterey = 12
    case ventura = 13
    case sonoma = 14
    case sequoia = 15
    case tahoe = 26
    
    public static func isAtLeast(_ version: MacOSVersion) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(
                majorVersion: version.rawValue,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }
}
