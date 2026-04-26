import Foundation
import SwiftServer

enum PlatformCLIBootstrap {
    static func bootstrap(dataDirPath: String, verbose: Bool, useSecondaryInstance: Bool) {
        SwiftServerHost.bootstrapWithOptions(
            dataDirPath: dataDirPath,
            verbose: verbose,
            useSecondaryInstance: useSecondaryInstance
        )
    }
}

final class PlatformCLIAPI {
    let platformAPI: PlatformAPI

    init(accountID: String = "default") {
        platformAPI = PlatformAPI(accountID: accountID)
    }

    func onThreadSelected(threadID: String, sendJSONEvents: @escaping @Sendable (String) async -> Void) async throws {
        try await platformAPI.onThreadSelected(threadID: threadID) { events in
            let json = try encodeJSON(events)
            Task {
                await sendJSONEvents(json)
            }
        }
    }

    func subscribeToEvents(_ sendJSONEvents: @escaping @Sendable (String) async -> Void) {
        SwiftServerHost.setEventCallback { events in
            let json = try encodeJSON(events.map { $0.jsonObject() })
            await sendJSONEvents(json)
        }
    }

    func startEventPollingFromCurrentState() async throws {
        try await SwiftServerHost.startPollingFromCurrentState()
    }

    func validateDatabaseAccess() async throws {
        try await SwiftServerHost.validateDatabaseAccess()
    }

    func canAccessMessagesDir() async -> Bool {
        do {
            return try await SwiftServerHost.canAccessMessagesDir()
        } catch {
            return false
        }
    }

    func askForMessagesDirAccess() async throws {
        try await SwiftServerHost.askForMessagesDirAccess()
    }

    func askForAutomationAccess() async throws {
        try await SwiftServerHost.askForAutomationAccess()
    }

    func confirmUNCPrompt() async throws {
        try await SwiftServerHost.confirmUNCPrompt()
    }

    func disableMessagesNotifications() async throws {
        try await SwiftServerHost.disableMessagesNotifications()
    }

    func startSysPrefsOnboarding() {
        SwiftServerHost.startSysPrefsOnboarding()
    }

    func stopSysPrefsOnboarding() {
        SwiftServerHost.stopSysPrefsOnboarding()
    }

    func revealSettings() async {
        SwiftServerHost.revealSettings()
    }
}
