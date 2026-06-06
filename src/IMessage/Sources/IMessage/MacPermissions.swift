import AppKit
import ApplicationServices
import Contacts
import Darwin
import Foundation
import IMDatabase
import IMessageCore

public enum MacPermissionAuthStatus: String, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined = "not determined"
}

public enum MacPermissions {
    private static let accessManager = MessagesAccessManager()

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
        if (try? await canAccessMessagesDir()) == true {
            return
        }
        try await accessManager.requestAccess()
    }

    public static func hasMessagesDirAccessGrant() -> Bool {
        accessManager.hasAccessGrant
    }

    public static func canAccessMessagesDir() async throws -> Bool {
        if accessManager.hasAccessGrant {
            return true
        }
        return try await Task.detached(priority: .userInitiated) {
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
        if #available(macOS 10.15, *) {
            paths.append("\(home)/Library/Safari/CloudTabs.db")
        }

        var sawDenied = false
        for path in paths {
            switch fileAccessStatus(path) {
            case .authorized:
                return .authorized
            case .denied:
                sawDenied = true
            case .restricted, .notDetermined:
                continue
            }
        }
        return sawDenied ? .denied : .notDetermined
    }

    private static func fileAccessStatus(_ path: String) -> MacPermissionAuthStatus {
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        if fd != -1 {
            Darwin.close(fd)
            return .authorized
        }

        switch errno {
        case ENOENT:
            return .notDetermined
        case EPERM, EACCES:
            return .denied
        default:
            return .notDetermined
        }
    }

    private static func openSystemSecurityPrefs(_ prefPath: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(prefPath)") else { return }
        NSWorkspace.shared.open(url)
    }
}
