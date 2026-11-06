import AppKit
import Darwin
import IMessageCore

/// Controls Dock presence for the specific Messages process being coordinated.
enum MessagesDockSuppression {
    private static let currentSession: Int32 = -2
    private static let transitionDelay: TimeInterval = 0.5
    // Automation and lifecycle callbacks run on different threads. The restoration
    // and current-type writes must remain one transaction across both callers.
    private static let transitionLock = NSLock()
    private static let api = Result { try LaunchServices() }

    enum Presentation {
        case suppressed
        case foreground

        var types: [String] {
            switch self {
            case .suppressed: return ["UIElement", "invalid"]
            case .foreground: return ["Foreground"]
            }
        }
    }

    static func suppress(_ app: NSRunningApplication) throws {
        try setPresentation(of: app, target: .suppressed)
    }

    static func restore(_ app: NSRunningApplication) throws {
        try setPresentation(of: app, target: .foreground)
    }

    private static func setPresentation(of app: NSRunningApplication, target: Presentation) throws {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        guard app.bundleIdentifier == messagesBundleID, !app.isTerminated else {
            throw ErrorMessage("Cannot change Dock presence of an invalid Messages instance")
        }
        // Never take Dock presence away while the user is controlling Messages.
        if target == .suppressed, MessagesInstanceTarget.isActive(app) { return }
        let services = try api.get()
        let asn = try services.identity(for: app.processIdentifier)

        try apply(
            target: target,
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
                services.applicationType(for: asn)
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
        return services.applicationType(for: try services.identity(for: pid))
    }

    static func apply(
        target: Presentation = .suppressed,
        write: (_ key: String, _ value: String) throws -> Void,
        read: () -> String?,
        settle: () -> Void
    ) throws {
        let types = target.types
        // Avoid repeating transitions and settling delays on every preparation.
        let originalType = read()
        if originalType == types.last { return }
        do {
            for type in types {
                // launchservicesd permits a foreign process to restore this matching
                // type without root. A direct ApplicationType write can silently no-op.
                try write("LSApplicationTypeToRestore", type)
                try write("ApplicationType", type)
                guard read() == type else {
                    throw ErrorMessage("Messages Dock presentation did not take effect (\(type))")
                }
                if target == .suppressed { settle() }
            }
        } catch {
            // A failed second transition must not strand the Messages instance
            // as a UIElement after removing its Dock tile.
            if target == .suppressed, originalType == "Foreground" {
                let suppressionError = error
                do {
                    try apply(target: .foreground, write: write, read: read, settle: settle)
                } catch {
                    throw ErrorMessage("Dock suppression failed (\(suppressionError)); restoration also failed (\(error))")
                }
            }
            throw error
        }
    }

    private struct LaunchServices {
        typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
        typealias CopyInformation = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias SetInformation = @convention(c) (Int32, CFTypeRef, CFString, CFTypeRef, UnsafeMutableRawPointer?) -> Int32

        let createASN: CreateASN
        let copyInformation: CopyInformation
        let setInformation: SetInformation

        func identity(for pid: pid_t) throws -> CFTypeRef {
            guard let asn = createASN(nil, pid)?.takeRetainedValue() else {
                throw ErrorMessage("Could not obtain Messages LaunchServices identity")
            }
            return asn
        }

        func applicationType(for asn: CFTypeRef) -> String? {
            copyInformation(currentSession, asn, "ApplicationType" as CFString)?.takeRetainedValue() as? String
        }

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
            do {
                createASN = try symbol("_LSASNCreateWithPid", as: CreateASN.self)
                copyInformation = try symbol("_LSCopyApplicationInformationItem", as: CopyInformation.self)
                setInformation = try symbol("_LSSetApplicationInformationItem", as: SetInformation.self)
            } catch {
                dlclose(handle)
                throw error
            }
        }
    }
}
