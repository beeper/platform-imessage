import Foundation

struct System {
    /// "Darwin"
    let os: String
    /// e.g. "hostname.local"
    let node: String
    /// e.g. "24.3.0" (XNU version)
    let kernelVersion: String
    /// e.g. "Darwin Kernel Version 24.3.0: …"
    let kernelRelease: String
    /// e.g. "arm64"
    let architecture: String
    /// e.g. "Version 15.3.2 (Build 24D81)"
    let osVersion: String

    init?() {
        var info = utsname()
        guard uname(&info) == 0 else {
            return nil
        }

        func read<C>(_ keyPath: KeyPath<utsname, C>) -> String {
            withUnsafePointer(to: info[keyPath: keyPath]) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
            }
        }

        os = read(\.sysname)
        node = read(\.nodename)
        kernelVersion = read(\.release)
        kernelRelease = read(\.version)
        architecture = read(\.machine)
        osVersion = ProcessInfo().operatingSystemVersionString
    }
}
