import Foundation
@testable import IMessage
import Testing

@Test
func staleMessagesBookmarkPersistsUsableReplacement() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let originalURL = root.appendingPathComponent("original", isDirectory: true)
    let expectedURL = root.appendingPathComponent("Messages", isDirectory: true)
    try fileManager.createDirectory(at: originalURL, withIntermediateDirectories: true)
    let originalBookmark = try originalURL.bookmarkData(options: [.withSecurityScope])
    try fileManager.moveItem(at: originalURL, to: expectedURL)

    var isStale = false
    _ = try URL(
        resolvingBookmarkData: originalBookmark,
        options: [.withSecurityScope, .withoutUI],
        bookmarkDataIsStale: &isStale
    )
    try #require(isStale, "Moving the fixture folder must produce a stale bookmark")

    let suiteName = "MessagesAccessManagerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(originalBookmark, forKey: "TXTMessagesBookmark")

    let manager = MessagesAccessManager(userDefaults: defaults, expectedURL: expectedURL)
    try withExtendedLifetime(manager) {
        let replacement = try #require(defaults.data(forKey: "TXTMessagesBookmark"))
        let resolvedURL = try URL(
            resolvingBookmarkData: replacement,
            options: [.withSecurityScope, .withoutUI],
            bookmarkDataIsStale: &isStale
        )
        #expect(!isStale)
        #expect(resolvedURL.standardizedFileURL.path == expectedURL.standardizedFileURL.path)
    }
}
