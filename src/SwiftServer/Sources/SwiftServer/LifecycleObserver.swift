import OSLog
import AccessibilityControl
import Logging
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "lifecycle.observer")

final class LifecycleObserver {
    private(set) var events = Topic<Event>()

    private var activateToken: Accessibility.Observer.Token?
    private var deactivateToken: Accessibility.Observer.Token?
    private var hiddenToken: Accessibility.Observer.Token?
    private var shownToken: Accessibility.Observer.Token?

    private var windowMovedToken: Accessibility.Observer.Token?
    private var windowResizedToken: Accessibility.Observer.Token?
    private var windowCreatedToken: Accessibility.Observer.Token?

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
        case anyObservedWindowMoved
        case anyObservedWindowResized
    }
}
