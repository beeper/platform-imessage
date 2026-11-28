import AppKit
import ApplicationServices
import Contacts
import Darwin
import Foundation
import IMDatabase
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "mac-permissions")

public enum MacPermissionAuthStatus: String, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined = "not determined"
}

public enum MacPermissions {
    private static let accessManager = MessagesAccessManager()
    private static let lastFullDiskAccessFailure = Protected<String?>()

    public static var requiresFullDiskAccess: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    public enum AuthType: String {
        case accessibility
        case contacts
        case fullDiskAccess = "full-disk-access"
    }

    public static func getAuthStatus(_ type: AuthType) -> MacPermissionAuthStatus {
        switch type {
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .denied
        case .contacts:
            return contactsAuthStatus()
        case .fullDiskAccess:
            return fullDiskAccessAuthStatus()
        }
    }

    public static func askForAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSystemSecurityPrefs("Privacy_Accessibility")
        }
    }

    public static func askForContactsAccess() async throws -> MacPermissionAuthStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .notDetermined else {
            return contactsAuthStatus(status)
        }

        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return granted ? .authorized : .denied
    }

    public static func askForFullDiskAccess() {
        openSystemSecurityPrefs("Privacy_AllFiles")
    }

    public static func askForMessagesDirAccess() async throws {
        try await accessManager.requestAccess()
    }

    public static func canAccessMessagesDir() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            _ = try IMDatabase()
            return true
        }.value
    }

    public static func validateDatabaseAccess() async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try IMDatabase(createIndexes: true)
        }.value
    }

    public static func askForAutomationAccess() async throws {
        // Automation's TCC prompt is unreliable when OSA runs off the main actor.
        try await MainActor.run {
            try OSA.promptAutomationAccess()
        }
    }

    private static func contactsAuthStatus(_ status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)) -> MacPermissionAuthStatus {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    private static func fullDiskAccessAuthStatus() -> MacPermissionAuthStatus {
        let home = NSHomeDirectory()
        var paths = [
            "\(home)/Library/Safari/Bookmarks.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]

        var sawDenied = false
        var failures = [String]()
        for path in paths {
            let (status, errorCode) = fileAccessStatus(path)
            switch status {
            case .authorized:
                let wasFailing = lastFullDiskAccessFailure.withLock { last in
                    let wasFailing = last != nil
                    last = nil
                    return wasFailing
                }
                if wasFailing {
                    log.info("full disk access probe is now authorized via \(loggablePath(path, home: home))")
                }
                return .authorized
            case .denied:
                sawDenied = true
            case .restricted, .notDetermined:
                break
            }
            if let errorCode {
                failures.append("\(loggablePath(path, home: home)): \(String(cString: strerror(errorCode))) (errno \(errorCode))")
            }
        }

        let result: MacPermissionAuthStatus = sawDenied ? .denied : .notDetermined
        let summary = "full disk access probe is \(result.rawValue): \(failures.joined(separator: "; "))"
        let changed = lastFullDiskAccessFailure.withLock { last in
            let changed = last != summary
            last = summary
            return changed
        }
        if changed {
            log.warning("\(summary)")
        }
        return result
    }

    private static func loggablePath(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func fileAccessStatus(_ path: String) -> (MacPermissionAuthStatus, Int32?) {
        var errorCode: Int32 = 0
        let fd = path.withCString { cPath -> Int32 in
            let fd = Darwin.open(cPath, O_RDONLY)
            errorCode = errno
            return fd
        }
        if fd != -1 {
            Darwin.close(fd)
            return (.authorized, nil)
        }

        switch errorCode {
        case ENOENT:
            return (.notDetermined, errorCode)
        case EPERM, EACCES:
            return (.denied, errorCode)
        default:
            return (.notDetermined, errorCode)
        }
    }

    private static func openSystemSecurityPrefs(_ prefPath: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(prefPath)") else { return }
        NSWorkspace.shared.open(url)
    }
}
