import AppKit
import AccessibilityControl

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
        // we're too early in the launch process to use isLoggingEnabled/debugLog
        #if DEBUG
        print("MessagesAccessManager has initial URL: \(url != nil)")
        #endif
    }

    private func isExpectedURL(_ url: URL) -> Bool {
        url.standardized.path == expectedURL?.standardized.path
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        isExpectedURL(url)
    }

    func requestAccess() throws {
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
            // DispatchQueue.main won't work here because runModal is blocking
            DispatchQueue.global(qos: .background).async {
                try? PromptAutomation.confirmDirectoryAccess(buttonTitle: buttonTitle)
            }
        }
        let response = openPanel.runModal()
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
            throw ErrorMessage("Please give Texts access to the Messages directory")
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
        debugLog("MessagesAccessManager calling stopAccessingSecurityScopedResource")
        url?.stopAccessingSecurityScopedResource()
    }
}
