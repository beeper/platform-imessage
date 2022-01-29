import AccessibilityControl
import WindowControl

protocol WindowHidingManager {
    var isValid: Bool { get }
    var canReuseApp: Bool { get }

    func mainWindowFetched(_ mainWindow: Accessibility.Element) throws
    func appActivated(window: Accessibility.Element) throws
    func appDeactivated(window: Accessibility.Element) throws
}

final class SpacesWindowHidingManager: WindowHidingManager {
    let canReuseApp = true
    var isValid = true
    private var lastActiveDisplay: Display?
    private let space: Space

    init() throws {
        space = try Space(newSpaceOfKind: .fullscreen)

        #if DEBUG
        StarkSpace.all().forEach {
            print($0.identifier, $0.isNormal, $0.isFullscreen, $0.screens())
        }

        let existing = try Space.list()
        debugLog("[spaces] \(existing.count) space(s)")
        existing.forEach {
            debugLog("[spaces] * Name: \((try? $0.name()) as Any)")
            debugLog("[spaces] * Kind: \((try? $0.kind()) as Any)")
            debugLog("[spaces] * Owners: \((try? $0.owners()) ?? [])")
            debugLog("[spaces] * Level: \($0.level())")
        }
        // existing.filter { (try? $0.name()) == "1FBF2F7F-57EC-56E5-521F-556A305D1A61" }.forEach {
        //     $0.destroy()
        // }
        #endif
    }

    // returns last active display
    private static func moveWindow(_ window: Accessibility.Element, to space: Space) throws -> Display {
        #if NO_SPACES
        return .main
        #else
        let windowCG = try window.window()

        // FIXME: this doesn't seem to work consistently with multiple displays
        let lastActiveDisplay: Display
        if let lastActiveSpace = try? windowCG.currentSpaces(.allVisibleSpaces).first,
           let activeDisplay = try? Display.allOnline().first(where: { (try? $0.currentSpace()) == lastActiveSpace }) {
            lastActiveDisplay = activeDisplay
        } else {
            lastActiveDisplay = .main
        }
        let sw = StarkWindow(element: window.raw)
        StarkSpace.all().last?.addWindows([sw])
        StarkSpace.all().first?.removeWindows([sw])
        // try windowCG.moveToSpace(space)
        return lastActiveDisplay
        #endif
    }

    func mainWindowFetched(_ mainWindow: Accessibility.Element) throws {
        lastActiveDisplay = try Self.moveWindow(mainWindow, to: space)
    }

    func appActivated(window: Accessibility.Element) throws {
        guard let space = try? lastActiveDisplay?.currentSpace() else {
            debugLog("WindowHidingManager.appActivated: space not found")
            return
        }
        debugLog("WindowHidingManager.appActivated: moving window")
        // try window.window().moveToSpace(space)
    }

    func appDeactivated(window: Accessibility.Element) throws {
        debugLog("WindowHidingManager.appDeactivated: moving window")
        lastActiveDisplay = try Self.moveWindow(window, to: space)
    }
}

final class RelaunchWindowHidingManager: WindowHidingManager {
    let canReuseApp = false
    var isValid = true

    func mainWindowFetched(_ mainWindow: Accessibility.Element) throws {}

    func appActivated(window: Accessibility.Element) throws {
        debugLog("WindowHidingManager.appActivated: invalidating")
        self.isValid = false
    }

    func appDeactivated(window: Accessibility.Element) throws {}
}
