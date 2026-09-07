@testable import IMessage
import IMessageCore
import Foundation
import Testing

@Test
func unavailableDNDListRemainsDistinctFromAnEmptyList() throws {
    #expect(PlatformAPI.permanentDNDThreadIDs(from: nil) == nil)
    let emptyList = try #require(PlatformAPI.permanentDNDThreadIDs(from: [:]))
    #expect(emptyList.isEmpty)
}

@Test
func permanentDNDThreadIDsExcludeNonPermanentEntries() throws {
    let forever = Int(Date.distantFuture.timeIntervalSince1970)
    let result = try #require(PlatformAPI.permanentDNDThreadIDs(from: [
        "permanent": forever,
        "temporary": forever - 1,
    ]))

    #expect(result == ["permanent"])
}

@Test
func muteStateUsesPermanentDNDEntries() {
    let forever = Int(Date.distantFuture.timeIntervalSince1970)

    #expect(PlatformAPI.muteState(forDNDIdentifier: "thread", from: nil) == nil)
    #expect(PlatformAPI.muteState(forDNDIdentifier: "thread", from: [:]) == false)
    #expect(PlatformAPI.muteState(forDNDIdentifier: "thread", from: ["thread": forever]) == true)
    #expect(PlatformAPI.muteState(forDNDIdentifier: "thread", from: ["thread": forever - 1]) == false)
}

@Test
func muteVerificationAcceptsPublicationAfterFiveSeconds() async throws {
    let publicationTime = ProcessInfo.processInfo.systemUptime + 5.3
    try await PlatformAPI.verifyMuteState(muted: false, operationID: "delayed-publication-test") {
        ProcessInfo.processInfo.systemUptime < publicationTime
    }
}

@Test
func muteVerificationFailsWhenStateDoesNotChange() async {
    await #expect(throws: ErrorMessage.self) {
        try await PlatformAPI.verifyMuteState(muted: true, operationID: "unchanged-state-test", timeout: 0.05) {
            false
        }
    }
}

@Test
func muteVerificationDoesNotTreatUnknownAsUnmuted() async {
    await #expect(throws: ErrorMessage.self) {
        try await PlatformAPI.verifyMuteState(muted: false, operationID: "unknown-state-test", timeout: 0.05) {
            nil
        }
    }
}

@Test
func muteVerificationPropagatesCancellation() async {
    let task = Task {
        try await PlatformAPI.verifyMuteState(muted: true, operationID: "cancelled-verification-test") { false }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}
