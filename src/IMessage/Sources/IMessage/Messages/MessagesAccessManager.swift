import AppKit
import AccessibilityControl
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "messages-access-manager")

final class MessagesAccessManager: NSObject, NSOpenSavePanelDelegate {
    enum AccessError: Error {
        case userCancelled
    }

    private static let messagesBookmarkKey = "TXTMessagesBookmark"

    private let expectedURL: URL?
    private let userDefaults: UserDefaults

    private var url: URL?

    init(
        userDefaults: UserDefaults = .standard,
        expectedURL: URL? = MessagesPaths.messagesDirectory
    ) {
        self.userDefaults = userDefaults
        self.expectedURL = expectedURL
        super.init()
        restoreAccess()
    }

    private func restoreAccess() {
        guard let bookmark = userDefaults.data(forKey: Self.messagesBookmarkKey) else { return }
        do {
            var isStale = false
            var isLegacy = false
            let resolvedURL: URL
            do {
                resolvedURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &isStale)
            } catch {
                // Before scoped bookmarks were saved, we persisted ordinary bookmarks.
                isLegacy = true
                isStale = false
                resolvedURL = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &isStale)
            }
            guard isExpectedURL(resolvedURL) else {
                log.warning("Saved Messages bookmark resolves to an unexpected directory")
                return
            }
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                log.warning("Could not restore security-scoped access to the Messages directory")
                return
            }
            url = resolvedURL
            if isStale || isLegacy {
                // A stale bookmark can still grant access. Refresh it while that
                // access is active instead of forcing the user to select it again.
                do {
                    try saveBookmark(for: resolvedURL)
                } catch {
                    log.warning("Could not refresh Messages bookmark; retaining current access: \(error)")
                }
            }
            log.debug("Restored Messages directory access")
        } catch {
            log.warning("Could not resolve saved Messages bookmark: \(error)")
        }
    }

    private func saveBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        userDefaults.set(bookmark, forKey: Self.messagesBookmarkKey)
    }

    private func isExpectedURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path == expectedURL?.standardizedFileURL.path
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        isExpectedURL(url)
    }

    @MainActor
    private func activateApp() {
        guard NSApplication.shared.mainWindow == nil else {
            return
        }
        NSApplication.shared.prepareAndActivate()
    }

    @MainActor
    func requestAccess() async throws {
        let buttonTitle = "Grant Access"
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = false
        openPanel.prompt = buttonTitle
        openPanel.message = "Please grant access to the Messages folder. It should already be selected for you."
        openPanel.directoryURL = expectedURL
        activateApp()
        if Accessibility.isTrusted() {
            DispatchQueue.global(qos: .background).async {
                try? PromptAutomation.confirmDirectoryAccess(buttonTitle: buttonTitle)
            }
        }
        let response = if let window = NSApp.mainWindow {
            await openPanel.beginSheetModal(for: window)
        } else {
            openPanel.runModal()
        }

        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                UserDefaults.standard.removeObject(forKey: "NSNavLastRootDirectory") // to make sure future NSOpenPanels don't show the Messages directory
                UserDefaults.standard.synchronize()
            }
        }

        guard response == .OK else {
            throw AccessError.userCancelled
        }
        guard let url = openPanel.url, isExpectedURL(url) else {
            throw ErrorMessage("Please give Beeper access to the Messages directory")
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ErrorMessage("Could not authorize access to the Messages directory")
        }
        do {
            try saveBookmark(for: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
        if let previousURL = self.url {
            previousURL.stopAccessingSecurityScopedResource()
        }
        self.url = url
    }

    deinit {
        log.debug("MessagesAccessManager calling stopAccessingSecurityScopedResource")
        if let url {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
