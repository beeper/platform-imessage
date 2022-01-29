// https://github.com/tombell/stark/tree/main/Stark/Source/API

import AppKit
import SkyLight

private let kAXFullscreenAttribute = "AXFullScreen"

private let starkVisibilityOptionsKey = "visible"

private let SLSScreenIDKey = "Display Identifier"
private let SLSSpaceIDKey = "ManagedSpaceID"
private let SLSSpacesKey = "Spaces"

private let NSScreenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

public class StarkSpace: NSObject {
    private static let connectionID = SLSMainConnectionID()

    public static func all() -> [StarkSpace] {
        var spaces: [StarkSpace] = []

        let displaySpacesInfo = SLSCopyManagedDisplaySpaces(connectionID).takeRetainedValue() as NSArray

        displaySpacesInfo.forEach {
            guard let spacesInfo = $0 as? [String: AnyObject] else {
                return
            }

            guard let identifiers = spacesInfo[SLSSpacesKey] as? [[String: AnyObject]] else {
                return
            }

            identifiers.forEach {
                guard let identifier = $0[SLSSpaceIDKey] as? uint64 else {
                    return
                }

                spaces.append(StarkSpace(identifier: identifier))
            }
        }

        return spaces
    }

    public static func active() -> StarkSpace {
        StarkSpace(identifier: SLSGetActiveSpace(connectionID))
    }

    static func current(for screen: NSScreen) -> StarkSpace? {
        let identifier = SLSManagedDisplayGetCurrentSpace(connectionID, screen.identifier as CFString)

        return StarkSpace(identifier: identifier)
    }

    static func spaces(for window: StarkWindow) -> [StarkSpace] {
        var spaces: [StarkSpace] = []

        let identifiers = SLSCopySpacesForWindows(connectionID,
                                                  7,
                                                  [window.identifier] as CFArray).takeRetainedValue() as NSArray

        all().forEach {
            if identifiers.contains($0.identifier) {
                spaces.append(StarkSpace(identifier: $0.identifier))
            }
        }

        return spaces
    }

    init(identifier: uint64) {
        self.identifier = identifier
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let space = object as? StarkSpace else {
            return false
        }

        return identifier == space.identifier
    }

    public var identifier: uint64

    public var isNormal: Bool {
        SLSSpaceGetType(StarkSpace.connectionID, identifier) == 0
    }

    public var isFullscreen: Bool {
        SLSSpaceGetType(StarkSpace.connectionID, identifier) == 4
    }

    public func screens() -> [NSScreen] {
        if !NSScreen.screensHaveSeparateSpaces {
            return NSScreen.screens
        }

        let displaySpacesInfo = SLSCopyManagedDisplaySpaces(StarkSpace.connectionID).takeRetainedValue() as NSArray

        var screen: NSScreen?

        displaySpacesInfo.forEach {
            guard let spacesInfo = $0 as? [String: AnyObject] else {
                return
            }

            guard let screenIdentifier = spacesInfo[SLSScreenIDKey] as? String else {
                return
            }

            guard let identifiers = spacesInfo[SLSSpacesKey] as? [[String: AnyObject]] else {
                return
            }

            identifiers.forEach {
                guard let identifier = $0[SLSSpaceIDKey] as? uint64 else {
                    return
                }

                if identifier == self.identifier {
                    screen = NSScreen.screen(for: screenIdentifier)
                }
            }
        }

        if screen == nil {
            return []
        }

        return [screen!]
    }

    public func windows(_ options: [String: AnyObject] = [:]) -> [StarkWindow] {
        StarkWindow.all(options).filter { $0.spaces().contains(self) }
    }

    public func addWindows(_ windows: [StarkWindow]) {
        SLSAddWindowsToSpaces(StarkSpace.connectionID, windows.map(\.identifier) as CFArray, [identifier] as CFArray)
    }

    public func removeWindows(_ windows: [StarkWindow]) {
        SLSRemoveWindowsFromSpaces(StarkSpace.connectionID, windows.map(\.identifier) as CFArray, [identifier] as CFArray)
    }
}

public class StarkWindow: NSObject {
    private static let systemWideElement = AXUIElementCreateSystemWide()

    public static func all(_ options: [String: AnyObject] = [:]) -> [StarkWindow] {
        App.all().flatMap { $0.windows(options) }
    }

    public static func focused() -> StarkWindow? {
        var app: AnyObject?
        AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &app)

        if app == nil {
            return nil
        }

        var window: AnyObject?

        // swiftlint:disable:next force_cast
        let result = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &window)

        if result != .success {
            return nil
        }

        // swiftlint:disable:next force_cast
        return StarkWindow(element: window as! AXUIElement)
    }

    public init(element: AXUIElement) {
        self.element = element
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let window = object as? StarkWindow else {
            return false
        }

        return identifier == window.identifier
    }

    private var element: AXUIElement

    public var identifier: CGWindowID {
        var identifier: CGWindowID = 0
        _AXUIElementGetWindow(element, &identifier)
        return identifier
    }

    public var app: App {
        App(pid: pid())
    }

    public var screen: NSScreen {
        let windowFrame = frame
        var lastVolume: CGFloat = 0
        var lastScreen = NSScreen()

        for screen in NSScreen.screens {
            let screenFrame = screen.frameIncludingDockAndMenu
            let intersection = windowFrame.intersection(screenFrame)
            let volume = intersection.size.width * intersection.size.height

            if volume > lastVolume {
                lastVolume = volume
                lastScreen = screen
            }
        }

        return lastScreen
    }

    public var title: String {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)

        if result != .success {
            return ""
        }

        if let title = value as? String {
            return title
        }

        return ""
    }

    public var frame: CGRect {
        CGRect(origin: topLeft, size: size)
    }

    public var topLeft: CGPoint {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)

        var topLeft = CGPoint.zero

        if result == .success {
            // swiftlint:disable:next force_cast
            if !AXValueGetValue(value as! AXValue, AXValueType.cgPoint, &topLeft) {
                topLeft = CGPoint.zero
            }
        }

        return topLeft
    }

    public var size: CGSize {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)

        var size = CGSize.zero

        if result == .success {
            // swiftlint:disable:next force_cast
            if !AXValueGetValue(value as! AXValue, AXValueType.cgSize, &size) {
                size = CGSize.zero
            }
        }

        return size
    }

    public var isMain: Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXMainAttribute as CFString, &value)

        if result != .success {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return false
    }

    public var isStandard: Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)

        if result != .success {
            return false
        }

        if let subrole = value as? String {
            return subrole == kAXStandardWindowSubrole
        }

        return false
    }

    public var isFullscreen: Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXFullscreenAttribute as CFString, &value)

        if result != .success {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return false
    }

    public var isMinimized: Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)

        if result != .success {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return false
    }

    public func setFrame(_ frame: CGRect) {
        setTopLeft(frame.origin)
        setSize(frame.size)
    }

    public func setTopLeft(_ topLeft: CGPoint) {
        var val = topLeft
        let value = AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &val)!
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    public func setSize(_ size: CGSize) {
        var val = size
        let value = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &val)!
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    public func maximize() {
        setFrame(screen.frameIncludingDockAndMenu)
    }

    public func minimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, true as CFTypeRef)
    }

    public func unminimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
    }

    public func focus() {
        let result = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)

        if result != .success {
            return
        }

        if let app = NSRunningApplication(processIdentifier: pid()) {
            app.activate(options: NSApplication.ActivationOptions.activateIgnoringOtherApps)
        }
    }

    public func spaces() -> [StarkSpace] {
        StarkSpace.spaces(for: self)
    }

    private func pid() -> pid_t {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)

        if result != .success {
            return 0
        }

        return pid
    }
}

public class App: NSObject {
    public static func find(_ name: String) -> App? {
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }

        guard app != nil else {
            return nil
        }

        return App(pid: app!.processIdentifier)
    }

    public static func all() -> [App] {
        NSWorkspace.shared.runningApplications.map { App(pid: $0.processIdentifier) }
    }

    public static func focused() -> App? {
        if let app = NSWorkspace.shared.frontmostApplication {
            return App(pid: app.processIdentifier)
        }

        return nil
    }

    init(pid: pid_t) {
        element = AXUIElementCreateApplication(pid)
        app = NSRunningApplication(processIdentifier: pid)!
    }

    init(app: NSRunningApplication) {
        element = AXUIElementCreateApplication(app.processIdentifier)
        self.app = app
    }

    private var element: AXUIElement

    private var app: NSRunningApplication

    public var name: String { app.localizedName ?? "" }

    public var bundleId: String { app.bundleIdentifier ?? "" }

    public var processId: pid_t { app.processIdentifier }

    public var isActive: Bool { app.isActive }

    public var isHidden: Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXHiddenAttribute as CFString, &value)

        if result != .success {
            return false
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return false
    }

    public var isTerminated: Bool {
        app.isTerminated
    }

    public func windows() -> [StarkWindow] {
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(element, kAXWindowsAttribute as CFString, 0, 100, &values)

        if result != .success {
            return []
        }

        let elements = values! as [AnyObject]

        // swiftlint:disable:next force_cast
        return elements.map { StarkWindow(element: $0 as! AXUIElement) }
    }

    public func windows(_ options: [String: AnyObject] = [:]) -> [StarkWindow] {
        let visible = options[starkVisibilityOptionsKey] as? Bool ?? false

        if visible {
            return windows().filter { !$0.app.isHidden && $0.isStandard && !$0.isMinimized }
        }

        return windows()
    }

    public func activate() -> Bool {
        app.activate(options: .activateAllWindows)
    }

    public func focus() -> Bool {
        app.activate(options: .activateIgnoringOtherApps)
    }

    public func show() -> Bool {
        app.unhide()
    }

    public func hide() -> Bool {
        app.hide()
    }

    public func terminate() -> Bool {
        app.terminate()
    }
}

extension NSScreen {
    public static func all() -> [NSScreen] {
        screens
    }

    public static func focused() -> NSScreen? {
        main
    }

    public static func screen(for identifier: String) -> NSScreen? {
        screens.first { $0.identifier == identifier }
    }

    public var identifier: String {
        guard let number = deviceDescription[NSScreenNumberKey] as? NSNumber else {
            return ""
        }

        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value).takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    public var frameIncludingDockAndMenu: CGRect {
        let primaryScreen = NSScreen.screens.first
        var frame = self.frame
        frame.origin.y = primaryScreen!.frame.height - frame.height - frame.origin.y
        return frame
    }

    public var frameWithoutDockOrMenu: CGRect {
        let primaryScreen = NSScreen.screens.first
        var frame = visibleFrame
        frame.origin.y = primaryScreen!.frame.height - frame.height - frame.origin.y
        return frame
    }

    public var next: NSScreen? {
        let screens = NSScreen.screens

        if var index = screens.firstIndex(of: self) {
            index += 1

            if index == screens.count {
                index = 0
            }

            return screens[index]
        }

        return nil
    }

    public var previous: NSScreen? {
        let screens = NSScreen.screens

        if var index = screens.firstIndex(of: self) {
            index -= 1

            if index == -1 {
                index = screens.count - 1
            }

            return screens[index]
        }

        return nil
    }

    public func currentSpace() -> StarkSpace? {
        StarkSpace.current(for: self)
    }

    public func spaces() -> [StarkSpace] {
        StarkSpace.all().filter { $0.screens().contains(self) }
    }
}
