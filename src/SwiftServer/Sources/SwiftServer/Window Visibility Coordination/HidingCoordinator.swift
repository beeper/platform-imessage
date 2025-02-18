import Cocoa
import Combine
import Logging

private let log = Logger(swiftServerLabel: "hiding-coordinator")

/**
 * Coordinates requests to hide an application in order to combat it being
 * rapidly hidden and unhidden, causing unwanted flickering.
 */
final class HidingCoordinator {
    private var stream = CurrentValueSubject<Request, Never>(.noop)
    var app: NSRunningApplication?
    private var requestHandler: AnyCancellable?
    private var debouncingDelay: RunLoop.SchedulerTimeType.Stride

    private enum Request: CaseIterable, Hashable {
        case hide
        case noop
    }

    init(debouncingFor delay: RunLoop.SchedulerTimeType.Stride) {
        self.debouncingDelay = delay
        beginHandlingRequests()
    }

    deinit {
        log.debug("deinit")
        requestHandler?.cancel()
    }
}

extension HidingCoordinator {
    /**
     * Requests that the app be hidden.
     *
     * This request is overridden (effectively ignored) if a request to unhide occurs
     * before the debouncing period passes.
     */
    func requestHide() {
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
        guard let app else {
            log.warning("tried to unhide, but no app is set")
            return
        }

        log.debug(stream.value == .hide ? "immediately unhiding, overriding a previous hide request" : "immediately unhiding")
        stream.send(.noop)
        app.unhide()
    }
}

extension HidingCoordinator {
    private func beginHandlingRequests() {
        requestHandler = stream
            .debounce(for: debouncingDelay, scheduler: RunLoop.main)
            .sink { [weak self] latestRequest in
                guard let self else { return }
                log.debug("servicing hide request: \(latestRequest) (debounce: \(debouncingDelay.magnitude))")

                switch latestRequest {
                case .hide: app?.hide()
                default: break
                }
            }
    }
}
