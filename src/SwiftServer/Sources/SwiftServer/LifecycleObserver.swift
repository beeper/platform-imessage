import OSLog
import AccessibilityControl
import Logging
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "lifecycle.observer")

// this class is only intended to be used from a thread with an available
// `RunLoop` (e.g. via `RunLoopConveyor`)
final class LifecycleObserver {
    private(set) var events = Topic<Event>()
    private(set) var lastLayoutChange = Protected<Date?>()
    private(set) var lastFocusedUIElementChange = Protected<Date?>()

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?
    private var hiddenToken: Accessibility.Observer.Token?
    private var shownToken: Accessibility.Observer.Token?

    private var windowMovedToken: Accessibility.Observer.Token?
    private var windowResizedToken: Accessibility.Observer.Token?
    private var windowCreatedToken: Accessibility.Observer.Token?

    private var titleChangedToken: Accessibility.Observer.Token?
    private var layoutChangedToken: Accessibility.Observer.Token?
    private var focusedUIElementChangedToken: Accessibility.Observer.Token?

    init() {}
}

extension LifecycleObserver {
    /// Observations are registered on the current `RunLoop`, so this method
    /// should only be called from a thread with a valid `RunLoop`.
    func beginObserving(app: Accessibility.Element) throws {
        log.debug("going to observe app AX events for element: \(app)")

        activateToken = try app.observe(.applicationActivated) { [weak events] _ in
            // (this can be called even if the app is already activated, e.g.
            // when you click the dock)
            events?.broadcast(.appActivated)
        }
        deactivateToken = try app.observe(.applicationDeactivated) { [weak events] _ in
            events?.broadcast(.appDeactivated)
        }
        shownToken = try app.observe(.applicationShown) { [weak events] _ in
            events?.broadcast(.appShown)
        }
        hiddenToken = try app.observe(.applicationHidden) { [weak events] _ in
            events?.broadcast(.appHidden)
        }
        windowCreatedToken = try app.observe(.windowCreated) { [weak events] _ in
            events?.broadcast(.windowCreated)
        }
        layoutChangedToken = try app.observe(.layoutChanged) { [weak lastLayoutChange] _ in
#if DEBUG
            log.debug("@@ AX: layoutChanged")
#endif
            lastLayoutChange?.withLock { $0 = Date() }
        }
        focusedUIElementChangedToken = try app.observe(.focusedUIElementChanged) { [weak lastFocusedUIElementChange, weak events] _ in
            events?.broadcast(.focusedUIElementChanged)
            lastFocusedUIElementChange?.withLock { $0 = Date() }
        }
#if DEBUG
        titleChangedToken = try app.observe(.titleChanged) { info in
            do {
                let windows = try app.appWindows().compactMap { try? $0.title() }
                log.info("@@ AX: window titles changed, now: \(windows)")
            } catch {
                log.error("failed to check windows after title changed: \(error)")
            }
        }
#endif
    }

    /// Observations are registered on the current `RunLoop`, so this method
    /// should only be called from a thread with a valid `RunLoop`.
    func beginObserving(window: Accessibility.Element) throws {
        log.debug("going to observe window AX events for window: \(window)")

        windowMovedToken = try window.observe(.windowMoved) { [weak events] _ in
            events?.broadcast(.anyObservedWindowMoved)
        }
        windowResizedToken = try window.observe(.windowResized) { [weak events] _ in
            events?.broadcast(.anyObservedWindowResized)
        }
    }
}

extension LifecycleObserver {
    enum Event {
        case appActivated
        case appDeactivated
        case appHidden
        case appShown
        case windowCreated
        case focusedUIElementChanged
        case anyObservedWindowMoved
        case anyObservedWindowResized
    }
}
