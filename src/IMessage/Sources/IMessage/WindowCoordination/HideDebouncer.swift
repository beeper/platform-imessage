import Cocoa
import Combine
import Logging

private let log = Logger(imessageLabel: "hiding-coordinator")

/**
 * Coordinates requests to hide an application in order to combat it being
 * rapidly hidden and unhidden, causing unwanted flickering.
 *
 * `@MainActor`: it was always main-affine (the debounce is scheduled on
 * `RunLoop.main` and every caller is on the main actor); the annotation makes
 * that compiler-checked and the class `Sendable`, so coordinators that hold one
 * can be `Sendable` too. The init stays nonisolated so coordinators can be
 * constructed off-main; the request-handling subscription attaches lazily on
 * first (main-actor) use.
 */
@MainActor
final class HideDebouncer {
    private let stream = CurrentValueSubject<Request, Never>(.noop)
    var app: NSRunningApplication?
    private var requestHandler: AnyCancellable?
    private let debouncingDelay: RunLoop.SchedulerTimeType.Stride

    private enum Request: CaseIterable, Hashable {
        case hide
        case noop
    }

    nonisolated init(debouncingFor delay: RunLoop.SchedulerTimeType.Stride) {
        self.debouncingDelay = delay
    }

    // No explicit deinit: `requestHandler` (AnyCancellable) cancels itself when released.
}

extension HideDebouncer {
    /**
     * Requests that the app be hidden.
     *
     * This request is overridden (effectively ignored) if a request to unhide occurs
     * before the debouncing period passes.
     */
    func requestHide() {
        beginHandlingRequestsIfNeeded()
        guard let app else {
            log.warning("hide was requested, but no app is set")
            return
        }

        // for some reason, `isHidden` is often misaligned with the actual hidden state of the app, so this isn't a terrible concern
        // maybe stems from using the NSRunningApplication instance returned from the launch, refetching could help
        log.debug(app.isHidden ? "hide was requested (app is allegedly already hidden?)" : "hide was requested")
        stream.send(.hide)
    }

    /**
     * Immediately unhides the app.
     *
     * Should the debouncing period pass without a request to hide in the interim,
     * then the app isn't hidden, as a request to unhide overrides all preceding
     * requests to hide (that occur within the debouncing period).
     */
    func immediatelyUnhide() {
        beginHandlingRequestsIfNeeded()
        guard let app else {
            log.warning("tried to unhide, but no app is set")
            return
        }

        log.debug(stream.value == .hide ? "immediately unhiding, overriding a previous hide request" : "immediately unhiding")
        stream.send(.noop)
        app.unhide()
    }
}

extension HideDebouncer {
    private func beginHandlingRequestsIfNeeded() {
        guard requestHandler == nil else { return }
        requestHandler = stream
            .debounce(for: debouncingDelay, scheduler: RunLoop.main)
            .sink { [weak self] latestRequest in
                // The debounce already delivers on RunLoop.main, but the compiler
                // can't see that through Combine; hop explicitly to read `app`.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    log.debug("servicing hide request: \(latestRequest) (debounce: \(self.debouncingDelay.magnitude))")

                    switch latestRequest {
                    case .hide: self.app?.hide()
                    default: break
                    }
                }
            }
    }
}
