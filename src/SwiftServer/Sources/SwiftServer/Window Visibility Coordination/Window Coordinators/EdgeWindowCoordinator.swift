import Cocoa
import AccessibilityControl
import Logging

final class EdgeWindowCoordinator: WindowCoordinator {
    private let logger = Logger(swiftServerLabel: "edge-window-coordinator")
    
    var app: NSRunningApplication?
    
    var canReuseExtantInstance: Bool { true }
    
    init() {
        
    }
    
    func makeAutomatable(_ messagesWindow: Accessibility.Element) throws {
        var windowFrame: CGRect = try messagesWindow.frame()
        
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
        
    }
    
    func userManuallyDeactivated(_ app: NSRunningApplication) throws {
        
    }
}

