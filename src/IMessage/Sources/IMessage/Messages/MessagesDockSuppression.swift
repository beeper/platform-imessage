import AppKit
import Darwin
import IMessageCore

/// Controls Dock presence for the specific Messages process being coordinated.
enum MessagesDockSuppression {
    private static let currentSession: Int32 = -2
    private static let transitionDelay: TimeInterval = 0.5
    private static let api = Result { try LaunchServices() }

    static func suppress(_ app: NSRunningApplication) throws {
        try setPresentation(of: app, types: ["UIElement", "invalid"])
    }

    static func restore(_ app: NSRunningApplication) throws {
        try setPresentation(of: app, types: ["Foreground"])
    }

    private static func setPresentation(of app: NSRunningApplication, types: [String]) throws {
        guard app.bundleIdentifier == messagesBundleID, !app.isTerminated else {
            throw ErrorMessage("Cannot change Dock presence of an invalid Messages instance")
        }
        let services = try api.get()
        guard let asn = services.createASN(nil, app.processIdentifier)?.takeRetainedValue() else {
            throw ErrorMessage("Could not obtain Messages LaunchServices identity")
        }

        // Automation preparation is frequent; avoid repeating the transitions
        // and their settling delays while the desired type is still in effect.
        if try applicationType(for: app.processIdentifier) == types.last { return }
        try apply(
            types: types,
            write: { key, value in
                guard !app.isTerminated else {
                    throw ErrorMessage("Messages terminated while changing Dock presence")
                }
                let status = services.setInformation(currentSession, asn, key as CFString, value as CFString, nil)
                guard status == noErr else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
            },
            read: {
                services.copyInformation(currentSession, asn, "ApplicationType" as CFString)?.takeRetainedValue() as? String
            },
            settle: {
                // Allow the UIElement transition to remove an existing Dock tile
                // before applying the unknown type that survives URL handling.
                Thread.sleep(forTimeInterval: transitionDelay)
            }
        )
    }

    static func applicationType(for pid: pid_t) throws -> String? {
        let services = try api.get()
        guard let asn = services.createASN(nil, pid)?.takeRetainedValue() else {
            return nil
        }
        return services.copyInformation(currentSession, asn, "ApplicationType" as CFString)?.takeRetainedValue() as? String
    }

    static func apply(
        types: [String] = ["UIElement", "invalid"],
        write: (_ key: String, _ value: String) throws -> Void,
        read: () -> String?,
        settle: () -> Void
    ) throws {
        for type in types {
            // launchservicesd permits a foreign process to restore this matching
            // type without root. A direct ApplicationType write can silently no-op.
            try write("LSApplicationTypeToRestore", type)
            try write("ApplicationType", type)
            guard read() == type else {
                throw ErrorMessage("Messages Dock presentation did not take effect (\(type))")
            }
            settle()
        }
    }

    private struct LaunchServices {
        typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
        typealias CopyInformation = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias SetInformation = @convention(c) (Int32, CFTypeRef, CFString, CFTypeRef, UnsafeMutableRawPointer?) -> Int32

        let createASN: CreateASN
        let copyInformation: CopyInformation
        let setInformation: SetInformation

        init() throws {
            let path = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices"
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                throw ErrorMessage("Could not load LaunchServices for Messages Dock presentation")
            }
            // Keep this image loaded for the cached function pointers' lifetime.
            func symbol<T>(_ name: String, as type: T.Type) throws -> T {
                guard let pointer = dlsym(handle, name) else {
                    throw ErrorMessage("Missing LaunchServices symbol: \(name)")
                }
                return unsafeBitCast(pointer, to: type)
            }
            createASN = try symbol("_LSASNCreateWithPid", as: CreateASN.self)
            copyInformation = try symbol("_LSCopyApplicationInformationItem", as: CopyInformation.self)
            setInformation = try symbol("_LSSetApplicationInformationItem", as: SetInformation.self)
        }
    }
}
