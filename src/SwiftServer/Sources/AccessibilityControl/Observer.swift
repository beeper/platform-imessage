import Foundation
import ApplicationServices

private func observerCallback(
    observer _: AXObserver,
    element _: AXUIElement,
    notification _: CFString,
    info: CFDictionary,
    context: UnsafeMutableRawPointer?
) {
    guard let context = context,
          let info = info as? [AnyHashable: Any]
    else { return }
    Unmanaged<Box<Accessibility.Observer.Callback>>
        .fromOpaque(context)
        .takeUnretainedValue()
        .value(info)
}

extension Accessibility {
    public struct Notification: AccessibilityPhantomName {
        public let value: String
        public init(_ value: String) {
            self.value = value
        }
    }

    public final class Observer {
        public final class Token {
            private let remove: () -> Void
            fileprivate init(remove: @escaping () -> Void) {
                self.remove = remove
            }
            deinit { remove() }
        }

        public typealias Callback = (_ info: [AnyHashable: Any]) -> Void

        private let raw: AXObserver

        // no need to retain the entire observer so long as the individual
        // tokens are retained
        public init(pid: pid_t, on runLoop: RunLoop = .current) throws {
            var raw: AXObserver?
            try check(AXObserverCreateWithInfoCallback(pid, observerCallback, &raw))
            guard let raw = raw else {
                throw AccessibilityError(.failure)
            }
            self.raw = raw

            let cfLoop = runLoop.getCFRunLoop()
            let src = AXObserverGetRunLoopSource(raw)
            // the source is auto-removed once `raw` is deinitialized
            CFRunLoopAddSource(cfLoop, src, .defaultMode)
        }

        // the token must be retained
        public func observe(
            _ notification: Notification,
            for element: Element,
            callback: @escaping Callback
        ) throws -> Token {
            let callback = Box(callback)
            let cfNotif = notification.value as CFString
            try check(
                AXObserverAddNotification(
                    raw,
                    element.raw,
                    cfNotif,
                    // the callback is retained by `Token`
                    Unmanaged.passUnretained(callback).toOpaque()
                )
            )
            return Token {
                // we retain the observer here as well, to keep the run loop source
                // around
                AXObserverRemoveNotification(self.raw, element.raw, cfNotif)
                _ = callback
            }
        }
    }
}

extension Accessibility.Element {

    // the token must be retained
    public func observe(
        _ notification: Accessibility.Notification,
        on runLoop: RunLoop = .current,
        callback: @escaping Accessibility.Observer.Callback
    ) throws -> Accessibility.Observer.Token {
        try Accessibility.Observer(pid: pid(), on: runLoop)
            .observe(notification, for: self, callback: callback)
    }

}
