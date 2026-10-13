import Foundation
import NodeAPI
import IMessage
import IMessageCore

enum IMessageNodeExports {
    @NodeActor
    static let reportErrorMessage: @Sendable (String) -> Void = {
        let sentryQueue = try? NodeAsyncQueue(label: "imessage-node-sentry")
        return { message in
            try? sentryQueue?.run {
                try Node.texts.Sentry.captureMessage(message)
            }
        }
    }()
}

#NodeModule {
    IMessageHost.bootstrap()

    var dict: [String: NodePropertyConvertible] = try [
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

        "confirmUNCPrompt": NodeFunction {
            try await IMessageHost.confirmUNCPrompt()
        },

        "disableMessagesNotifications": NodeFunction {
            try await IMessageHost.disableMessagesNotifications()
        },

        "revealSettings": NodeFunction {
            IMessageHost.revealSettings()
            return undefined
        }
    ]

    dict["SystemSettingsOnboarding"] = try [
        "start": NodeFunction { () async in
            await MainActor.run {
                SystemSettingsOnboarding.start()
            }
        },
        "stop": NodeFunction { () async in
            await MainActor.run {
                SystemSettingsOnboarding.stop()
            }
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
        "askForMessagesDirAccess": NodeFunction {
            try await MacPermissions.askForMessagesDirAccess()
        },
        "canAccessMessagesDir": NodeFunction {
            try await MacPermissions.canAccessMessagesDir()
        },
        "validateDatabaseAccess": NodeFunction {
            try await MacPermissions.validateDatabaseAccess()
        },
        "askForAutomationAccess": NodeFunction {
            try await MacPermissions.askForAutomationAccess()
        },
    ]
    dict["PlatformAPI"] = try PlatformAPINodeWrapper.constructor()

    return dict
}
