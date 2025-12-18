import AppKit
import Combine
import ExceptionCatcher
import Logging
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "menu-maintainer")
/**
 * injects menu items into the main menu (technically owned by Electron, not us;
 * we just share a memory space), and makes sure they stay there
 */
@MainActor
final class MenuMaintainer {
    private var menuItemsToMaintain = [NSMenuItem]()
    private var maintainer: Task<Void, Never>?

    // continuously maintain menu items for some time; the main menu shifts
    // around a lot during app startup (from Electron, AppKit and Beeper Desktop
    // updating stuff) and observing the menu via notifications doesn't seem to
    // work well
    private static var maintenancePeriod: TimeInterval {
        Defaults.swiftServer.double(forKey: DefaultsKeys.settingsMenuItemInjectionMaintenancePeriod)
    }

    static let shared = MenuMaintainer()
}

extension MenuMaintainer {
    private func spawnMaintainer() {
        maintainer = Task {
            let beganInjectionAttempts = Date()
            var hasSucceeded = false

            while beganInjectionAttempts.timeIntervalSinceNow > -Self.maintenancePeriod {
                do {
                    try menuItemsToMaintain.forEach(injectIntoSuitableMenuIfNeeded)
                    log.info("successfully ensured that the menu items are injected")
                    hasSucceeded = true
                } catch {
                    log.warning("couldn't ensure all menu items are present: \(error)")
                }
                let ms = 1_000 * Defaults.swiftServer.double(forKey: DefaultsKeys.settingsMenuItemInjectionMaintenanceInterval)
                try? await Task.sleep(nanoseconds: 1_000_000 * UInt64(ms.rounded()))
            }

            if !hasSucceeded {
                log.error("timed out trying to maintain menu item after \(Self.maintenancePeriod)s, giving up!")
            }
            maintainer = nil
        }
    }

    private func ensureMaintainer() {
        if maintainer == nil {
            spawnMaintainer()
        }
    }

    func add(maintaining menuItem: NSMenuItem) {
        menuItemsToMaintain.append(menuItem)
        ensureMaintainer()
        dumpMainMenu(reason: "given menu item to inject asap")
    }
}

// MARK: - Injection

private enum InjectionError: Error {
    /** app is definitely not done initializing yet, the menu items are incorrect (i.e. are Electron's defaults) */
    case notReadyYet
    /** there isn't a main menu at all */
    case noMainMenu
    /** couldn't find a menu item within the main menu to inject into */
    case noSuitableMenuItem
}

@MainActor
private func injectIntoSuitableMenuIfNeeded(_ new: NSMenuItem) throws(InjectionError) {
    dumpMainMenu(reason: "trying to inject")

    guard let mainMenu = NSApp.mainMenu else {
        log.error("couldn't inject, no main menu? (yet?)")
        throw .noMainMenu
    }

    let targetMenu = try findSuitableInjectionTarget(in: mainMenu)

    if targetMenu.numberOfItems < 1 {
        log.warning("menu item we're injecting into is empty, menu item being injected will be alone")
    }

    if targetMenu.items.contains(new) {
        log.debug("injection target already has the item, not injecting redundantly")
        return
    }

    let insertingAfter = findIdealInjectionIndex(within: targetMenu) ?? {
        log.warning("couldn't find ideal injection index within submenu, falling back to beginning")
        return 0
    }()

    do {
        try ExceptionCatcher.catch {
            if let parent = new.parent, let parentSubmenu = parent.submenu {
                // the menu can get swapped out after injecting the item for
                // whatever reason (maybe the "Services" menu being injected?)
                //
                // detect this situation and remove it from the old parent menu
                // first, so we're able to add it back. or else you get an
                // internal consistency exception
                log.debug("about to inject menu item, but it already has a parent: \(parent), removing from parent first")
                parentSubmenu.removeItem(new)
            }

            targetMenu.insertItem(new, at: insertingAfter)
        }

        log.info("injected menu item at index \(insertingAfter) within \(targetMenu)")
    } catch {
        log.error("couldn't inject menu item: \(error)")
    }
}

@MainActor
private func findIdealInjectionIndex(within menu: NSMenu) -> Int? {
    let find = { (title: String) -> Int? in
        let index = menu.indexOfItem(withTitle: title)
        guard index > -1 else {
            return nil
        }
        // we want to insert after the item
        return index + 1
    }

    return find("Settings…") ?? find("Preferences…")
}

@MainActor
private func findSuitableInjectionTarget(in mainMenu: NSMenu) throws(InjectionError) -> NSMenu {
    let defaultTitle = Defaults.swiftServer.string(forKey: DefaultsKeys.settingsMenuItemInjectionDefinitelyNotReadyMenuItemTitle)
    if let defaultTitle, !defaultTitle.isEmpty {
        let definitelyNotReady = mainMenu.items.contains { item in
            // default Electron menu
            item.title == defaultTitle
        }
        if definitelyNotReady {
            log.error("definitely not ready yet (found menu titled \(defaultTitle))")
            throw .notReadyYet
        }
    }

    let injectionTargetSubstring = Defaults.swiftServer.string(forKey: DefaultsKeys.settingsMenuItemInjectionTargetSubstring) ?? ""
    guard let menuItem = mainMenu.items.first(where: {
        $0.title.localizedCaseInsensitiveContains(injectionTargetSubstring)
    }) else {
        log.error("couldn't find main app menu (target substring: \(injectionTargetSubstring))")
        throw .noSuitableMenuItem
    }

    guard let submenu = menuItem.submenu else {
        log.error("injection target submenu \(menuItem) lacks a submenu")
        throw .noSuitableMenuItem
    }

    // look for items like "About Beeper", "Logout of Beeper…", etc. to verify
    // that we're injecting into the right menu
    guard mainMenu.items.contains(where: { $0.title.localizedCaseInsensitiveContains("Beeper") }) else {
        log.error("injection target submenu needs to contain an item with title mentioning \"Beeper\"")
        throw .noSuitableMenuItem
    }

    return submenu
}

// MARK: -

@MainActor
private func dumpMainMenu(reason: String? = nil) {
#if DEBUG
    let prefix = if let reason {
        "main menu dump (\(reason))"
    } else {
        "main menu dump"
    }

    guard let mainMenu = NSApp.mainMenu else {
        log.error("\(prefix): no main menu!")
        return
    }

    log.debug("\(prefix): main menu has \(mainMenu.numberOfItems) items")
    for (itemIndex, item) in mainMenu.items.enumerated() {
        log.debug("\(prefix): item \(itemIndex + 1)/\(mainMenu.numberOfItems). \(item)")
    }
#endif
}
