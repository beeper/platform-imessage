@testable import IMessage
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
