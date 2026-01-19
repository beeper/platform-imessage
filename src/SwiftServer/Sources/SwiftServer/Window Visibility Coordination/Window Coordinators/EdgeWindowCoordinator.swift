import Cocoa
import AccessibilityControl
import Logging

// TODO: (@pmanot) - rename
@available(macOS 11, *)
final class EdgeWindowCoordinator: WindowCoordinator {
    private let logger = Logger(swiftServerLabel: "edge-window-coordinator")
    
    var app: NSRunningApplication?
    var originalWindowFrame: CGRect? = nil
    
    var canReuseExtantInstance: Bool { true }
    
    init() {
        
    }
    
    func makeAutomatable(_ messagesWindow: Accessibility.Element) throws {
        logger.debug("makeAutomatable")
        var windowFrame: CGRect = try messagesWindow.frame()
//        originalWindowFrame = windowFrame
        
        windowFrame.origin.x = -windowFrame.size.width + 1
        windowFrame.origin.y = (NSScreen.main?.frame.size.height ?? 10000)
        
        try messagesWindow.setFrame(windowFrame)
    }
    
    func automationDidComplete(_ window: Accessibility.Element) throws {
        //        app?.hide()
    }
    
    
    func reset(_ window: Accessibility.Element) throws {
        
    }
    
    func userManuallyActivated(_ app: NSRunningApplication) throws {
//        guard let originalWindowFrame else { return }
//        try app.elements.mainWindow.setFrame(originalWindowFrame)
    }
    
    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
//        originalWindowFrame = (try? app.elements.mainWindow.frame()) ?? originalWindowFrame
    }
}

