import AppKit
import Cocoa
import Combine
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
