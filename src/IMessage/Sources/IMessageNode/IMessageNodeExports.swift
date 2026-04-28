import Foundation
import NodeAPI
import IMessage
import IMessageCore

#NodeModule {
    IMessageHost.bootstrap()

    var dict: [String: NodePropertyConvertible] = try [
        "isMessagesAppInDock": NodeProperty { _ in
            IMessageHost.isMessagesAppInDock
        },

        "isNotificationsEnabledForMessages": NodeProperty { _ in
            IMessageHost.isNotificationsEnabledForMessages
        },

        "enabledExperiments": NodeProperty { _ in
            IMessageHost.enabledExperiments
        } set: { args in
            IMessageHost.enabledExperiments = try args.first?.as(String.self) ?? ""
        },

        "useSecondaryMessagesInstance": NodeProperty { _ in
            IMessageHost.useSecondaryMessagesInstance
        } set: { args in
            IMessageHost.useSecondaryMessagesInstance = try args.first?.as(Bool.self) ?? false
        },

        "isLoggingEnabled": NodeProperty { _ in
            IMessageHost.isLoggingEnabled
        } set: { args in
            IMessageHost.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
        },

        "isPHTEnabled": NodeProperty { _ in
            IMessageHost.isPHTEnabled
        } set: { args in
            IMessageHost.isPHTEnabled = try args.first?.as(Bool.self) ?? false
        },

        "askForMessagesDirAccess": NodeFunction {
            try await IMessageHost.askForMessagesDirAccess()
        },

        "canAccessMessagesDir": NodeFunction {
            try await IMessageHost.canAccessMessagesDir()
        },

        "validateDatabaseAccess": NodeFunction {
            try await IMessageHost.validateDatabaseAccess()
        },

        "setEventCallback": NodeFunction { (onEvent: NodeFunction) in
            let eventQueue = try NodeAsyncQueue(label: "event-watcher-events")
            let sentryQueue = try? NodeAsyncQueue(label: "event-watcher-sentry")
            let onEvent = SendableBox(onEvent)
            IMessageHost.setEventCallback { events in
                try eventQueue.run {
                    let nodeEvents = try NodeBridgeUtilities.nodeArray(from: events.map { $0.jsonObject() })
                    try onEvent.value.call([nodeEvents])
                }
            } reportToSentry: { message in
                try? sentryQueue?.run {
                    try Node.texts.Sentry.captureMessage(message)
                }
            }
            return // needed to resolve a compile-time type ambiguity apparently
        },

        "startEventWatchingFromCurrentState": NodeFunction { () async throws in
            try await IMessageHost.startEventWatchingFromCurrentState()
            return
        },

        "askForAutomationAccess": NodeFunction {
            try await IMessageHost.askForAutomationAccess()
        },

        "confirmUNCPrompt": NodeFunction {
            try await IMessageHost.confirmUNCPrompt()
        },

        "disableMessagesNotifications": NodeFunction {
            try await IMessageHost.disableMessagesNotifications()
        },

        "removeMessagesFromDock": NodeFunction {
            IMessageHost.removeMessagesFromDock()
        },

        "killDock": NodeFunction {
            IMessageHost.killDock()
        },

        "revealSettings": NodeFunction {
            IMessageHost.revealSettings()
            return undefined
        }
    ]

    dict["SystemSettingsOnboarding"] = try [
        "start": NodeFunction {
            SystemSettingsOnboarding.start()
        },
        "stop": NodeFunction {
            SystemSettingsOnboarding.stop()
        },
    ]
    dict["MacPermissions"] = try [
        "getAuthStatus": NodeFunction { (type: String) in
            guard let authType = MacPermissions.AuthType(rawValue: type) else {
                throw ErrorMessage("unknown macOS permission type: \(type)")
            }
            return MacPermissions.getAuthStatus(authType).rawValue
        },
        "askForAccessibilityAccess": NodeFunction {
            MacPermissions.askForAccessibilityAccess()
            return undefined
        },
        "askForContactsAccess": NodeFunction { () async throws in
            try await MacPermissions.askForContactsAccess().rawValue
        },
        "askForFullDiskAccess": NodeFunction {
            MacPermissions.askForFullDiskAccess()
            return undefined
        },
    ]
    dict["PlatformAPI"] = try PlatformAPINodeWrapper.constructor()

    return dict
}
