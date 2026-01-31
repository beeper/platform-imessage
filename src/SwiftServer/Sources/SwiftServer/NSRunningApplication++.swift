import AppKit
import ApplicationServices
import Cocoa
import Combine
import AccessibilityControl
import BetterSwiftAXAdditions

extension NSRunningApplication {
    enum ObservationEvent {
        case didLaunch(NSRunningApplication, Notification)
        case didTerminate(NSRunningApplication, Notification)
        case didHide(NSRunningApplication, Notification)
        case didUnhide(NSRunningApplication, Notification)
        case didActivate(NSRunningApplication, Notification)
        case didDeactivate(NSRunningApplication, Notification)

        /// The application instance associated with the event.
        var app: NSRunningApplication {
            switch self {
                case .didLaunch(let app, _),
                        .didTerminate(let app, _),
                        .didHide(let app, _),
                        .didUnhide(let app, _),
                        .didActivate(let app, _),
                        .didDeactivate(let app, _):
                    return app
            }
        }

        /// The notification that triggered the event, if applicable.
        var notification: Notification {
            switch self {
                case .didLaunch(_, let notification), .didTerminate(_, let notification), .didHide(_, let notification), .didUnhide(_, let notification), .didActivate(_, let notification), .didDeactivate(_, let notification):
                    return notification
            }
        }
    }

    /// Events emitted by window observation via AXObserver.
    enum WindowEvent {
        case windowMoved(window: Accessibility.Element, info: [AnyHashable: Any])
        case windowResized(window: Accessibility.Element, info: [AnyHashable: Any])
        case windowCreated(window: Accessibility.Element, info: [AnyHashable: Any])

        var window: Accessibility.Element {
            switch self {
                case .windowMoved(let window, _),
                     .windowResized(let window, _),
                     .windowCreated(let window, _):
                    return window
            }
        }
    }
    
    /// Creates a publisher that monitors the lifecycle and behavior of an application with the given Bundle ID.
    func _publisher() -> AnyPublisher<ObservationEvent, Never> {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter
        
        let notifications: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        
        let notificationStream = Publishers.MergeMany(notifications.map { nc.publisher(for: $0) })
            .compactMap { [weak self] notification -> ObservationEvent? in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self == app else { return nil }
                
                switch notification.name {
                    case NSWorkspace.didLaunchApplicationNotification:      return .didLaunch(app, notification)
                    case NSWorkspace.didTerminateApplicationNotification:   return .didTerminate(app, notification)
                    case NSWorkspace.didActivateApplicationNotification:    return .didActivate(app, notification)
                    case NSWorkspace.didDeactivateApplicationNotification:  return .didDeactivate(app, notification)
                    case NSWorkspace.didHideApplicationNotification:        return .didHide(app, notification)
                    case NSWorkspace.didUnhideApplicationNotification:      return .didUnhide(app, notification)
                    default: return nil
                }
            }
        
        return notificationStream
            .eraseToAnyPublisher()
    }
}

extension NotificationCenter {
    /// Returns a publisher that emits events for any of the specified notification names.
    func publisher(for names: [Notification.Name], object: AnyObject? = nil) -> AnyPublisher<Notification, Never> {
        return Publishers.MergeMany(
            names.map { publisher(for: $0, object: object) }
        )
        .eraseToAnyPublisher()
    }
}

// MARK: - Window Event Publisher

/// Custom AXObserver callback that captures the element parameter
private func windowObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    info: CFDictionary?,
    context: UnsafeMutableRawPointer?
) {
    guard let context = context else { return }
    let holder = Unmanaged<WindowObserverContext>.fromOpaque(context).takeUnretainedValue()
    let axElement = Accessibility.Element(raw: element)
    let infoDict = (info as? [AnyHashable: Any]) ?? [:]
    holder.callback(axElement, notification as String, infoDict)
}

/// Context object for window observer callbacks
private class WindowObserverContext {
    let callback: (Accessibility.Element, String, [AnyHashable: Any]) -> Void

    init(callback: @escaping (Accessibility.Element, String, [AnyHashable: Any]) -> Void) {
        self.callback = callback
    }
}

/// Holds the AXObserver and context to keep them alive for the duration of the subscription.
private class WindowObservationHolder {
    var observer: AXObserver?
    var context: WindowObserverContext?
    var isObserving = true

    func stop() {
        isObserving = false
        observer = nil
        context = nil
    }
}

extension NSRunningApplication {
    /// Creates a publisher that emits events when the application's windows are moved, resized, or created.
    ///
    /// Uses AXObserver to monitor accessibility notifications for window changes.
    /// The publisher properly captures the window element that triggered each event.
    ///
    /// - Parameter runLoop: The run loop to receive events on. Defaults to `.main`.
    /// - Returns: A publisher emitting `WindowEvent` values, or `nil` if observation setup fails.
    func windowEventPublisher(on runLoop: RunLoop = .main) -> AnyPublisher<WindowEvent, Never>? {
        let pid = self.processIdentifier
        guard pid > 0 else { return nil }

        let subject = PassthroughSubject<WindowEvent, Never>()
        let holder = WindowObservationHolder()

        // Create the observer with our custom callback
        var observerRef: AXObserver?
        let result = AXObserverCreateWithInfoCallback(pid, windowObserverCallback, &observerRef)
        guard result == .success, let observer = observerRef else {
            return nil
        }
        holder.observer = observer

        // Create context that routes events to the subject
        let context = WindowObserverContext { [weak holder] element, notificationName, info in
            guard holder?.isObserving == true else { return }

            let event: WindowEvent
            switch notificationName {
            case kAXWindowMovedNotification:
                event = .windowMoved(window: element, info: info)
            case kAXWindowResizedNotification:
                event = .windowResized(window: element, info: info)
            case kAXWindowCreatedNotification:
                event = .windowCreated(window: element, info: info)
            default:
                return
            }
            subject.send(event)
        }
        holder.context = context

        // Register for notifications on the app element
        let appElement = AXUIElementCreateApplication(pid)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()

        let notifications = [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowCreatedNotification
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, contextPtr)
        }

        // Add to run loop
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(runLoop.getCFRunLoop(), source, .defaultMode)

        // Return a publisher that keeps the holder alive
        return subject
            .handleEvents(receiveCancel: { [holder] in
                // Stop observing first to prevent any more callbacks
                holder.stop()

                // Note: We don't manually remove notifications here because:
                // 1. Setting holder.observer = nil releases the AXObserver
                // 2. The AXObserver automatically removes its notifications when deallocated
                // 3. Manually removing can cause crashes if the app element is invalid
            })
            .eraseToAnyPublisher()
    }
}
