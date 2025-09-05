import AccessibilityControl
import ApplicationServices

public extension Accessibility.Notification {
    static let layoutChanged = Self(kAXLayoutChangedNotification)
    static let focusedUIElementChanged = Self(kAXFocusedUIElementChangedNotification)
    static let applicationActivated = Self(kAXApplicationActivatedNotification)
    static let applicationDeactivated = Self(kAXApplicationDeactivatedNotification)
    static let applicationShown = Self(kAXApplicationShownNotification)
    static let applicationHidden = Self(kAXApplicationHiddenNotification)
    static let windowMoved = Self(kAXWindowMovedNotification)
    static let windowResized = Self(kAXWindowResizedNotification)
    static let windowCreated = Self(kAXWindowCreatedNotification)
    static let titleChanged = Self(kAXTitleChangedNotification)
}
