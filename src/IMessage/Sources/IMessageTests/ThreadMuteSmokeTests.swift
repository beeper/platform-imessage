import AppKit
import Foundation
import IMessageCore
@testable import IMessage
import Testing

// Explicitly opt in with an existing sacrificial chat. Restore its original state.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_MUTE_SMOKE"] == "1"))
@MainActor
func concurrentMuteRequestsRemainIdempotent() async throws {
    Defaults.registerDefaults()
    let address = try #require(ProcessInfo.processInfo.environment["IMESSAGE_SMOKE_CHAT"])
    let oldSecondary = Preferences.useSecondaryMessagesInstance
    Preferences.useSecondaryMessagesInstance = true
    defer { Preferences.useSecondaryMessagesInstance = oldSecondary }
    let api = try PlatformAPI(accountID: "mute-smoke")
    let result = await Result<Void, Error>(catching: {
        let candidates = ["any;-;\(address)", "iMessage;-;\(address)"]
        let existing = Set(try await api.lookupExistingThreadGUIDs(guids: candidates))
        let threadID = try #require(candidates.first(where: existing.contains))
        try await api.onThreadSelected(threadID: threadID) { _ in }
        func currentState() async throws -> Bool {
            try await api.withMessagesController { controller in
                let cell = try #require(await controller.elements.selectedThreadCell)
                let states = Set(try cell.supportedActions().compactMap { action in
                    parseThreadAlertsActionLabel(
                        action.name.value,
                        hideAlertsLabel: LocalizedStrings.hideAlerts,
                        showAlertsLabel: LocalizedStrings.showAlerts
                    )?.isMuted
                })
                try #require(states.count == 1, "Requires an unambiguous live alerts action")
                return try #require(states.first)
            }
        }
        let original = try await currentState()
        print("MUTE_SMOKE original=\(original)")
        let updates = await Result<Void, Error>(catching: {
            for requested in [!original, original] {
                async let first: Void = api.updateThread(threadID: threadID, muted: requested)
                async let second: Void = api.updateThread(threadID: threadID, muted: requested)
                _ = try await (first, second)
                let observed = try await currentState()
                #expect(observed == requested)
            }
        })
        try await api.updateThread(threadID: threadID, muted: original)
        let restored = try await currentState()
        print("MUTE_SMOKE restored=\(restored)")
        #expect(restored == original)
        try updates.get()
    })
    try await api.dispose()
    try result.get()
}
