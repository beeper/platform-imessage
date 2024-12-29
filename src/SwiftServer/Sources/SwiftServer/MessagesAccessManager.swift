import AppKit
import AccessibilityControl
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "messages-access-manager")

final class MessagesAccessManager: NSObject, NSOpenSavePanelDelegate {
    enum AccessError: Error {
        case userCancelled
    }

    private static let messagesBookmarkKey = "TXTMessagesBookmark"

    private var expectedURL: URL?

    var url: URL?

    override init() {
        super.init()
        if let bookmark = UserDefaults.standard.data(forKey: Self.messagesBookmarkKey) {
            var isStale = false
            url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
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

    @MainActor func requestAccess() async throws {
        expectedURL = messagesDir
        let buttonTitle = "Grant Access"
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = false
        openPanel.prompt = buttonTitle
        openPanel.message = "Please grant access to the Messages folder. It should already be selected for you."
        openPanel.directoryURL = messagesDir
        if Accessibility.isTrusted() {
            DispatchQueue.global(qos: .background).async {
                try? PromptAutomation.confirmDirectoryAccess(buttonTitle: buttonTitle)
            }
        }
        let response = if let mw = NSApp.mainWindow {
            await openPanel.beginSheetModal(for: mw)
        } else {
            await openPanel.begin()
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
        let bookmark = try url.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: Self.messagesBookmarkKey)
        self.url?.stopAccessingSecurityScopedResource()
        self.url = url
    }

    deinit {
        log.debug("MessagesAccessManager calling stopAccessingSecurityScopedResource")
        url?.stopAccessingSecurityScopedResource()
    }
}
