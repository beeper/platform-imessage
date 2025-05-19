import AccessibilityControl
import AppKit
import SwiftServerFoundation
import Logging

// Directories like ~/Library/Messages are protected by MAC (Mandatory Access
// Control) even when not running under App Sandbox, so we need to use
// security-scoped URLs and bookmarks to manage access.
//
// https://mothersruin.com/software/Archaeology/reverse/bookmarks.html

private let log = Logger(swiftServerLabel: "bookmark")

// a PersistedBookmark instance is "resolved" when it has a valid
// security-scoped URL that has been resolved from a corresponding
// security-scoped bookmark.
final class PersistedBookmark: NSObject {
    private(set) var name: String?
    private(set) var desiredTarget: URL
    private(set) var persistenceKey: String
    private var userFacingCopyName: String?

    private var hasAccess = false

    private var currentSecurityScopedURL: URL? {
        didSet {
            if let currentSecurityScopedURL {
                log.debug("\(loggingName): resolved with security-scoped URL: \(currentSecurityScopedURL)")
            } else {
                log.debug("\(loggingName): became unresolved")
            }

            hasAccess = false
        }
    }

    init(accessing desiredTarget: URL, persistingWithKey key: String, name: String? = nil, userFacingCopyNoun: String? = nil) {
        self.desiredTarget = desiredTarget
        self.persistenceKey = key
        self.name = name
        self.userFacingCopyName = userFacingCopyNoun
    }

    enum Error: Swift.Error {
        // (potentially) user-facing:
        case panelDenied
        case panelNoSelection
        case panelIncorrectSelection(incorrectlyTargeted: URL)
        case noPersistedBookmark
        case bookmarkResolution
        case bookmarkBecameStale
        case bookmarkAccess
        case bookmarkCreation(error: any Swift.Error)

        // developer-facing:
        case unresolved
    }

    func beginAccess() throws(Error) {
        guard let currentSecurityScopedURL else {
            throw .unresolved
        }

        guard !hasAccess else {
            log.warning("\(loggingName): ignoring superfluous request to begin access; we should already have access")
            return
        }

        guard currentSecurityScopedURL.startAccessingSecurityScopedResource() else {
            throw .bookmarkAccess
        }

        log.debug("\(loggingName): successfully began access")
    }

    func stopAccess() {
        if hasAccess {
            if let currentSecurityScopedURL {
                currentSecurityScopedURL.stopAccessingSecurityScopedResource()
                log.debug("\(loggingName): stopped access to security-scoped URL")
            } else {
                log.warning("\(loggingName): thought we had access, but we don't actually have a security-scoped URL at all")
            }
        }

        log.debug("\(loggingName): don't need to stop access")
    }

    deinit {
        // NOTE: this isn't called for the statics
        log.debug("\(loggingName): releasing")
        stopAccess()
    }
}

extension PersistedBookmark.Error: CustomStringConvertible {
    var description: String {
        switch self {
        // (potentially) user-facing:
        case .panelDenied: "Access to Messages data was denied"
        case .panelNoSelection, .panelIncorrectSelection(_): "Incorrect directory selected by user when requesting access"
        case .noPersistedBookmark: "Access to Messages data is required"
        case .bookmarkResolution: "Couldn’t resolve access to Messages data"
        case .bookmarkBecameStale: "Access to Messages data became stale"
        case .bookmarkAccess: "Couldn’t access Messages data"
        case let .bookmarkCreation(_): "Couldn’t persist access to Messages data"

        // developer-facing:
        case .unresolved: "Tried to use unresolved persisted bookmark"
        }
    }
}

/** `~/Library` */
private let userLibrary: URL = {
    let properUserLibrary = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    return properUserLibrary ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
}()

// TODO: replace `messagesDir` global with this. this was written so we have an infallible way to get it
private let userMessagesDataDirectory: URL = {
    return userLibrary.appendingPathComponent("Messages", isDirectory: true)
}()

private let userPreferencesDirectory: URL = {
    return userLibrary
        .appendingPathComponent("Preferences", isDirectory: true)
        .appendingPathComponent("com.apple.MobileSMS.plist", isDirectory: false)
}()

extension PersistedBookmark {
    static let messages = PersistedBookmark(
        accessing: userMessagesDataDirectory,
        // keeping legacy name from Texts for backwards compatibility
        persistingWithKey: "TXTMessagesBookmark",
        name: "messages app data",
        userFacingCopyNoun: "the Messages app’s data"
    )

    static let preferences = PersistedBookmark(
        accessing: userPreferencesDirectory,
        persistingWithKey: "BEEPMessagesPreferencesBookmark",
        name: "messages prefs",
        userFacingCopyNoun: "the Messages app’s settings"
    )
}

private extension PersistedBookmark {
    var loggingName: String {
        name ?? "<unnamed>"
    }
}

// MARK: - Persistence

extension PersistedBookmark {
    var isResolved: Bool {
        currentSecurityScopedURL != nil
    }

    var hasPersisted: Bool {
        loadPersistedData() == nil
    }

    private func persist(bookmarkData bookmark: Data) {
        log.debug("\(loggingName): persisting bookmark data to \"\(persistenceKey)\"")
        UserDefaults.standard.set(bookmark, forKey: persistenceKey)
    }

    private func loadPersistedData() -> Data? {
        log.debug("\(loggingName): trying to load persisted data from \"\(persistenceKey)\"")
        return UserDefaults.standard.data(forKey: persistenceKey)
    }

    func resolveWithPersistedData() throws(Error) {
        guard let bookmarkData = loadPersistedData() else {
            throw .noPersistedBookmark
        }

        var isStale = false
        do {
            currentSecurityScopedURL = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        } catch {
            currentSecurityScopedURL = nil
            log.warning("\(loggingName): couldn't resolve security-scoped bookmark: \(String(reflecting: error))")
            throw .bookmarkResolution
        }

        if isStale {
            log.warning("\(loggingName): tried to resolve, but bookmark data is stale")
            currentSecurityScopedURL = nil
            throw .bookmarkBecameStale
        }
    }
}

// MARK: - Requesting Access

extension PersistedBookmark {
    private var targetsDirectory: Bool {
        // NOTE: this relies on correct usage of `isDirectory` when using `appendingPathComponent`, because:
        //
        //  11> URL(filePath: "/Users/")!.hasDirectoryPath
        // $R9: Bool = false
        // 12> URL(filePath: "/")!.appendingPathComponent("Users", isDirectory: true).hasDirectoryPath
        // $R10: Bool = true
        desiredTarget.hasDirectoryPath
    }

    @MainActor func interactivelyRequestResolutionPersisting(attemptingAutomation: Bool = true) async throws {
        let panelConfirmationButtonTitle = "Grant Access"

        let panel = NSOpenPanel()
        panel.delegate = self
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = targetsDirectory
        panel.canCreateDirectories = false
        panel.canChooseFiles = !targetsDirectory
        panel.prompt = panelConfirmationButtonTitle
        panel.message = "To continue, please grant Beeper access to \(userFacingCopyName ?? "the Messages folder"). It should already be selected for you."
        panel.directoryURL = desiredTarget

        if attemptingAutomation, Accessibility.isTrusted() {
            // TODO: do this with `Task` somehow
            DispatchQueue.main.async {
                do {
                    try PromptAutomation.confirmDirectoryAccess(buttonTitle: panelConfirmationButtonTitle)
                } catch {
                    log.warning("\(self.loggingName): couldn't automate open panel: \(error)")
                }
            }
        }

        let response = if let mainWindow = NSApp.mainWindow {
            await panel.beginSheet(mainWindow)
        } else {
            await panel.begin()
        }

        // make sure future open panels don't show the messages directory
        Task {
            let oneHundredMilliseconds = UInt64(1_000_000 * 100)
            try? await Task.sleep(nanoseconds: oneHundredMilliseconds)
            UserDefaults.standard.removeObject(forKey: "NSNavLastRootDirectory")
        }

        guard response == .OK else {
            throw Error.panelDenied
        }
        guard let securityScopedURL = panel.url else {
            throw Error.panelNoSelection
        }
        guard isTargetedBy(url: securityScopedURL) else {
            throw Error.panelIncorrectSelection(incorrectlyTargeted: securityScopedURL)
        }

        // to create a security-scoped bookmark from the security-scoped URL,
        // we need explicit security-scoped access
        let bookmarkData = try securityScopedURL.withSecurityScopedAccess { url in
            do {
                self.currentSecurityScopedURL = url
                return try url.bookmarkData()
            } catch {
                throw PersistedBookmark.Error.bookmarkCreation(error: error)
            }
        }

        persist(bookmarkData: bookmarkData)
    }
}

// MARK: - PersistedBookmark+NSOpenSavePanelDelegate

extension PersistedBookmark: NSOpenSavePanelDelegate {
    private func isTargetedBy(url other: URL) -> Bool {
        other.standardized.path == desiredTarget.standardized.path
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        isTargetedBy(url: url)
    }
}

private extension URL {
    func withSecurityScopedAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard startAccessingSecurityScopedResource() else {
            throw PersistedBookmark.Error.bookmarkAccess
        }
        defer { stopAccessingSecurityScopedResource() }

        return try body(self)
    }
}
