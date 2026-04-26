import Foundation
import NodeAPI
import SwiftServer

#NodeModule {
    SwiftServerHost.bootstrap()

    var dict: [String: NodePropertyConvertible] = try [
        "isMessagesAppInDock": NodeProperty { _ in
            SwiftServerHost.isMessagesAppInDock
        },

        "isNotificationsEnabledForMessages": NodeProperty { _ in
            SwiftServerHost.isNotificationsEnabledForMessages
        },

        "enabledExperiments": NodeProperty { _ in
            SwiftServerHost.enabledExperiments
        } set: { args in
            SwiftServerHost.enabledExperiments = try args.first?.as(String.self) ?? ""
        },

        "useSecondaryMessagesInstance": NodeProperty { _ in
            SwiftServerHost.useSecondaryMessagesInstance
        } set: { args in
            SwiftServerHost.useSecondaryMessagesInstance = try args.first?.as(Bool.self) ?? false
        },

        "isLoggingEnabled": NodeProperty { _ in
            SwiftServerHost.isLoggingEnabled
        } set: { args in
            SwiftServerHost.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
        },

        "isPHTEnabled": NodeProperty { _ in
            SwiftServerHost.isPHTEnabled
        } set: { args in
            SwiftServerHost.isPHTEnabled = try args.first?.as(Bool.self) ?? false
        },

        "askForMessagesDirAccess": NodeFunction {
            try await SwiftServerHost.askForMessagesDirAccess()
        },

        "canAccessMessagesDir": NodeFunction {
            try await SwiftServerHost.canAccessMessagesDir()
        },

        "validateDatabaseAccess": NodeFunction {
            try await SwiftServerHost.validateDatabaseAccess()
        },

        "setEventCallback": NodeFunction { (onEvent: NodeFunction) in
            let eventQueue = try NodeAsyncQueue(label: "polling-lifecycle-events")
            let sentryQueue = try? NodeAsyncQueue(label: "polling-lifecycle-sentry")
            let onEvent = SendableBox(onEvent)
            SwiftServerHost.setEventCallback { events in
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

        "startPollingFromCurrentState": NodeFunction { () async throws in
            try await SwiftServerHost.startPollingFromCurrentState()
            return
        },

        "askForAutomationAccess": NodeFunction {
            try await SwiftServerHost.askForAutomationAccess()
        },

        "confirmUNCPrompt": NodeFunction {
            try await SwiftServerHost.confirmUNCPrompt()
        },

        "disableMessagesNotifications": NodeFunction {
            try await SwiftServerHost.disableMessagesNotifications()
        },

        "removeMessagesFromDock": NodeFunction {
            SwiftServerHost.removeMessagesFromDock()
        },

        "killDock": NodeFunction {
            SwiftServerHost.killDock()
        },

        "revealSettings": NodeFunction {
            SwiftServerHost.revealSettings()
            return undefined
        }
    ]

    dict["startSysPrefsOnboarding"] = try NodeFunction {
        SwiftServerHost.startSysPrefsOnboarding()
    }
    dict["stopSysPrefsOnboarding"] = try NodeFunction {
        SwiftServerHost.stopSysPrefsOnboarding()
    }
    dict["PlatformAPI"] = try PlatformAPINodeWrapper.constructor()

    return dict
}
