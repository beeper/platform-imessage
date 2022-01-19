import SwiftUI
import AppKit

final class OnboardingManager {
    private var onboardingWindow: NSWindow?
    private var pollingTimer: Timer?
    private var initialWidth: CGFloat?

    private static let sysPrefsBundleID = "com.apple.systempreferences"
    private static let sysPrefsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sysPrefsBundleID)
    private static let sysPrefsTitle = sysPrefsURL.flatMap(Bundle.init(url:))?.localizedString(forKey: "System Preferences", value: nil, table: nil)

    static func isPrefsFocused() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.sysPrefsBundleID).first?.isActive == true
    }

    static func getPrefsWindowBounds() -> CGRect? {
        guard let allWindowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary],
              let sysPrefWinInfo = allWindowInfos.first(where: { $0[kCGWindowOwnerName] as? String == Self.sysPrefsTitle }),
              // todo review force cast
              let bounds = CGRect(dictionaryRepresentation: sysPrefWinInfo[kCGWindowBounds] as! CFDictionary)
        else {
            return nil
        }
        return bounds
    }

    func createOrUpdateWindow(_ bounds: CGRect) {
        var rect = NSRectFromCGRect(bounds)
        rect.origin.y = (NSScreen.main?.frame.height ?? 0) - rect.size.height - rect.origin.y

        let authPromptShown = initialWidth ?? bounds.width > bounds.width
        if onboardingWindow == nil {
            debugLog("OnboardingManager: creating window")
            onboardingWindow = NSWindow(
                contentRect: rect,
                styleMask: [.fullSizeContentView],
                backing: .buffered, defer: false
            )

            onboardingWindow?.contentView = NSHostingView(rootView: OnboardingView())
            onboardingWindow?.isOpaque = false
            onboardingWindow?.isMovableByWindowBackground = false
            onboardingWindow?.isReleasedWhenClosed = false
            onboardingWindow?.isMovable = false
            onboardingWindow?.ignoresMouseEvents = true
            onboardingWindow?.backgroundColor = NSColor(calibratedHue: 0, saturation: 1.0, brightness: 0, alpha: 0)
            onboardingWindow?.level = .floating
            onboardingWindow?.makeKeyAndOrderFront(nil)

            initialWidth = onboardingWindow?.frame.width
        } else {
            debugLog("OnboardingManager: setting window frame")
            onboardingWindow?.setFrame(rect, display: true, animate: !authPromptShown)
        }
        onboardingWindow?.setIsVisible(Self.isPrefsFocused() && !authPromptShown)
    }

    func createWindow() {
        DispatchQueue.main.async {
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                guard let bounds = Self.getPrefsWindowBounds() else {
                    self.onboardingWindow?.setIsVisible(false)
                    return
                }
                self.createOrUpdateWindow(bounds)
            }
            self.pollingTimer?.fire()
        }
    }

    func closeWindow() {
        debugLog("OnboardingManager: closing window")
        self.onboardingWindow?.close()
        self.onboardingWindow = nil
        self.initialWidth = nil
        self.pollingTimer?.invalidate()
    }

    deinit {
        debugLog("OnboardingManager: deinit")
        self.closeWindow()
    }
}
