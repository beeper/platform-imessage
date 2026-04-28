import Foundation
import IMessage

enum IMessageCLIBootstrap {
    static func bootstrap(dataDirPath: String, verbose: Bool, useSecondaryInstance: Bool) {
        IMessageHost.bootstrapWithOptions(
            dataDirPath: dataDirPath,
            verbose: verbose,
            useSecondaryInstance: useSecondaryInstance
        )
    }
}

final class IMessageCLIAPI {
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
        IMessageHost.setEventCallback { events in
            let json = try encodeJSON(events.map { $0.jsonObject() })
            await sendJSONEvents(json)
        }
    }

    func startEventWatchingFromCurrentState() async throws {
        try await IMessageHost.startEventWatchingFromCurrentState()
    }

    func validateDatabaseAccess() async throws {
        try await IMessageHost.validateDatabaseAccess()
    }

    func canAccessMessagesDir() async -> Bool {
        do {
            return try await IMessageHost.canAccessMessagesDir()
        } catch {
            return false
        }
    }

    func askForMessagesDirAccess() async throws {
        try await IMessageHost.askForMessagesDirAccess()
    }

    func askForAutomationAccess() async throws {
        try await IMessageHost.askForAutomationAccess()
    }

    func confirmUNCPrompt() async throws {
        try await IMessageHost.confirmUNCPrompt()
    }

    func disableMessagesNotifications() async throws {
        try await IMessageHost.disableMessagesNotifications()
    }

    func revealSettings() async {
        IMessageHost.revealSettings()
    }
}
