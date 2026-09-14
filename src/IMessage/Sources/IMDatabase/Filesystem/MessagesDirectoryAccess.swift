import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "messages-directory-access")

package enum MessagesDirectoryAccess {
    package static let bookmarkKey = "TXTMessagesBookmark"

    /// Returns an active security-scoped URL. The caller must stop accessing it when finished.
    package static func restoreSavedBookmark(for expectedURL: URL, userDefaults: UserDefaults = .standard) -> URL? {
        guard let bookmark = userDefaults.data(forKey: bookmarkKey) else { return nil }
        do {
            var needsRefresh = false
            let resolvedURL: URL
            do {
                resolvedURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &needsRefresh)
            } catch {
                // Before scoped bookmarks were saved, we persisted ordinary bookmarks.
                resolvedURL = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &needsRefresh)
                needsRefresh = true
            }
            guard resolvedURL.standardizedFileURL.path == expectedURL.standardizedFileURL.path else {
                log.warning("Saved Messages bookmark resolves to an unexpected directory")
                return nil
            }
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                log.warning("Could not restore security-scoped access to the Messages directory")
                return nil
            }
            if needsRefresh {
                // A stale bookmark can still grant access. Refresh it while that access is active.
                do {
                    let replacement = try resolvedURL.bookmarkData(options: [.withSecurityScope])
                    userDefaults.set(replacement, forKey: bookmarkKey)
                } catch {
                    log.warning("Could not refresh Messages bookmark; retaining current access: \(error)")
                }
            }
            log.debug("Restored Messages directory access")
            return resolvedURL
        } catch {
            log.warning("Could not resolve saved Messages bookmark: \(error)")
            return nil
        }
    }
}
