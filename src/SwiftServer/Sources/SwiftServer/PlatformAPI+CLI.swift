import AppKit
import Foundation
import IMDatabase
import Logging
import SwiftServerFoundation

public enum PlatformCLIBootstrap {
    private static let lock = NSLock()
    private static var didBootstrap = false

    public static func bootstrap(dataDirPath: String, verbose: Bool, useSecondaryInstance: Bool) {
        PlatformEnvironment.applyCLIDefaults()
        PlatformEnvironment.setLoggingDirectory(dataDirPath)
        PlatformEnvironment.setUseSecondaryInstance(useSecondaryInstance)
        Preferences.isLoggingEnabled = verbose
        Defaults.registerDefaults()

        lock.lock()
        defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        LoggingSystem.bootstrap { identifier in
            SwiftServerLogHandler(
                identifier: identifier,
                logLevel: verbose ? .trace : .info
            )
        }

        Task {
            try? await LogFileCoordinator.shared?.tryTrimming()
        }
    }
}

public final class PlatformCLIAPI {
    public let platformAPI: PlatformAPI
    private let accessManager = MessagesAccessManager()

    public init(accountID: String = "default") {
        platformAPI = PlatformAPI(accountID: accountID)
    }

    public func onThreadSelected(threadID: String, sendJSONEvents: @escaping @Sendable (String) async -> Void) async throws {
        try await platformAPI.onThreadSelected(threadID: threadID) { events in
            let json = try encodeJSON(events)
            Task {
                await sendJSONEvents(json)
            }
        }
    }

    public func subscribeToEvents(_ sendJSONEvents: @escaping @Sendable (String) async -> Void) {
        PollingLifecycle.shared.setEventCallback { events in
            let json = try encodeJSON(events.map { $0.jsonObject() })
            await sendJSONEvents(json)
        }
    }

    public func startEventPollingFromCurrentState() async throws {
        let (lastRowID, lastDateRead) = try await DetachedWork.run {
            let db = try IMDatabase()
            return (try db.lastMessageRowID(), try db.maxMessageDateRead())
        }
        try PollingLifecycle.shared.startPollingFromCurrentState(lastRowID: lastRowID, lastDateRead: lastDateRead)
    }

    public func validateDatabaseAccess() async throws {
        try await DetachedWork.run {
            _ = try IMDatabase(createIndexes: true)
        }
    }

    public func canAccessMessagesDir() async -> Bool {
        do {
            try await DetachedWork.run {
                _ = try IMDatabase()
            }
            return true
        } catch {
            return false
        }
    }

    public func askForMessagesDirAccess() async throws {
        try await accessManager.requestAccess()
    }

    public func askForAutomationAccess() async throws {
        try await MainActor.run {
            try OSA.promptAutomationAccess()
        }
    }

    public func confirmUNCPrompt() async throws {
        try await DetachedWork.run(priority: .background) {
            try PromptAutomation.confirmUNCPrompt()
        }
    }

    public func disableMessagesNotifications() async throws {
        try await DetachedWork.run(priority: .background) {
            _ = try PromptAutomation.disableNotificationsForApp(named: "Messages")
            Defaults.playSoundEffects = false
        }
    }

    public func startSysPrefsOnboarding() {
        SysPrefsOnboarding.start()
    }

    public func stopSysPrefsOnboarding() {
        SysPrefsOnboarding.stop()
    }

    public func revealSettings() async {
        await MainActor.run {
            guard #available(macOS 13, *) else { return }
            SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        }
    }
}
