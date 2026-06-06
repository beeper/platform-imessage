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

    private let expectedURL = MessagesPaths.messagesDirectory

    var url: URL?

    override init() {
        super.init()
        if let bookmark = UserDefaults.standard.data(forKey: Self.messagesBookmarkKey) {
            var isStale = false
            url = (try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? (try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale))
            if isStale || url?.startAccessingSecurityScopedResource() == false {
                url = nil
            }
        }

        log.debug("do we have an initial url? \(url != nil)")
    }

    private func isExpectedURL(_ url: URL) -> Bool {
        url.standardized.path == expectedURL?.standardized.path
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

    @MainActor func requestAccess() async throws {
        let buttonTitle = "Grant Access"
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = false
        openPanel.prompt = buttonTitle
        openPanel.message = "Please grant access to the Messages folder. It should already be selected for you."
        openPanel.directoryURL = MessagesPaths.messagesDirectory
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
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.messagesBookmarkKey)
        self.url?.stopAccessingSecurityScopedResource()
        self.url = url
    }

    deinit {
        log.debug("MessagesAccessManager calling stopAccessingSecurityScopedResource")
        url?.stopAccessingSecurityScopedResource()
    }
}
