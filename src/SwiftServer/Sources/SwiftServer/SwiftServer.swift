import NodeAPI
import Foundation
import WindowControl
import SwiftServerFoundation
import Logging
import IMDatabase

private let log = Logger(swiftServerLabel: "swift-server")

enum Preferences {
    static var isLoggingEnabled: Bool = false
    static var isPHTEnabled: Bool = false
    static var enabledExperiments: String = ""
    static var useSecondaryMessagesInstance: Bool = false
}

#NodeModule {
    // this needs to be bootstrapped as early as possible, because it needs to
    // be ready by the first `debugLog` call, or else subsequent calls to that
    // function are dropped
    LoggingSystem.bootstrap({ identifier in
        SwiftServerLogHandler(identifier: identifier)
    })

    Task {
        // we trim as we log (within reason), but always try to do it on startup
        try? await LogFileCoordinator.shared?.tryTrimming()
    }

    let greeting = "howdy from SwiftServer!"
    if let system = System() {
        log.info("\(greeting) (\(system.os) \(system.kernelVersion) \(system.architecture), \(system.osVersion))")
    } else {
        log.info("\(greeting)")
    }

    Defaults.registerDefaults()

    Task { @MainActor in
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.settingsMenuItemInjection) else { return }

        if #available(macOS 13, *) {
            log.debug("trying to inject settings menu item whenever possible")
            MenuMaintainer.shared.add(maintaining: SettingsView.menuItem)
        } else {
            log.debug("couldn't inject settings menu item, macOS 13 or later is needed")
        }
    }

    // strongly retained by askForMessagesDirAccess, deinit called on exit
    let accessManager = MessagesAccessManager()
    func validateDatabaseAccess() throws {
        _ = try IMDatabase(createIndexes: true)
    }

    var dict: [String: NodePropertyConvertible] = try [
        "isMessagesAppInDock": NodeProperty { _ in
            Defaults.isAppInDock(bundleID: messagesBundleID)
        },

        "isNotificationsEnabledForMessages": NodeProperty { _ in
            Defaults.isNotificationsEnabledForApp(bundleID: messagesBundleID)
        },

        "enabledExperiments": NodeProperty { _ in
            Preferences.enabledExperiments
        } set: { args in
            Preferences.enabledExperiments = try args.first?.as(String.self) ?? ""
        },

        "useSecondaryMessagesInstance": NodeProperty { _ in
            Preferences.useSecondaryMessagesInstance
        } set: { args in
            Preferences.useSecondaryMessagesInstance = try args.first?.as(Bool.self) ?? false
        },

        "isLoggingEnabled": NodeProperty { _ in
            Preferences.isLoggingEnabled
        } set: { args in
            Preferences.isLoggingEnabled = try args.first?.as(Bool.self) ?? false
        },

        "isPHTEnabled": NodeProperty { _ in
            Preferences.isPHTEnabled
        } set: { args in
            Preferences.isPHTEnabled = try args.first?.as(Bool.self) ?? false
        },

        "askForMessagesDirAccess": NodeFunction {
            try await accessManager.requestAccess()
        },

        "canAccessMessagesDir": NodeFunction {
            try await NodeBridgeUtilities.offNodeActor {
                _ = try IMDatabase()
                return true
            }
        },

        "validateDatabaseAccess": NodeFunction {
            try await NodeBridgeUtilities.offNodeActor {
                try validateDatabaseAccess()
            }
        },

        "setEventCallback": NodeFunction { (onEvent: NodeFunction) in
            let eventQueue = try NodeAsyncQueue(label: "polling-lifecycle-events")
            let sentryQueue = try? NodeAsyncQueue(label: "polling-lifecycle-sentry")
            let onEvent = SendableBox(onEvent)
            PollingLifecycle.shared.setEventCallback { events in
                try await eventQueue.run {
                    var values = [any NodeValueConvertible]()
                    for event in events {
                        values.append(try await event.nodeValue())
                    }
                    try await onEvent.value.call([values])
                }
            } reportToSentry: { message in
                try? sentryQueue?.run {
                    try Node.texts.Sentry.captureMessage(message)
                }
            }

            return // needed to resolve a compile-time type ambiguity apparently
        },

        "startPollingFromCurrentState": NodeFunction { () async throws in
            let (lastRowID, lastDateRead) = try await NodeBridgeUtilities.offNodeActor {
                let db = try IMDatabase()
                return (try db.lastMessageRowID(), try db.maxMessageDateRead())
            }
            try PollingLifecycle.shared.startPollingFromCurrentState(
                lastRowID: lastRowID,
                lastDateRead: lastDateRead
            )
            return
        },

        "askForAutomationAccess": NodeFunction {
            try await MainActor.run {
                try OSA.promptAutomationAccess()
            }
        },

        "confirmUNCPrompt": NodeFunction {
            try await NodeBridgeUtilities.offNodeActor(priority: .background) {
                try PromptAutomation.confirmUNCPrompt()
            }
        },

        "disableMessagesNotifications": NodeFunction {
            try await NodeBridgeUtilities.offNodeActor(priority: .background) {
                try PromptAutomation.disableNotificationsForApp(named: "Messages")
                Defaults.playSoundEffects = false
            }
        },

        "removeMessagesFromDock": NodeFunction {
            Defaults.removeAppFromDock(bundleID: messagesBundleID)
        },

        "killDock": NodeFunction {
            Dock.runningApplication()?.terminate()
        },

        "revealSettings": NodeFunction {
            log.debug("told to reveal settings window")
            Task { @MainActor in
                guard #available(macOS 13, *) else {
                    log.error("can't reveal settings on macOS <13")
                    return
                }
                guard let window = SettingsWindowController.shared.window else {
                    log.error("can't reveal settings, no window?")
                    return
                }
                log.debug("revealing settings window")
                window.makeKeyAndOrderFront(nil)
            }
            // needed or else we get a type ambiguity error?
            return undefined
        }
    ]

    dict["startSysPrefsOnboarding"] = try NodeFunction {
        SysPrefsOnboarding.start()
    }
    dict["stopSysPrefsOnboarding"] = try NodeFunction {
        SysPrefsOnboarding.stop()
    }
    dict["PlatformAPI"] = try PlatformAPINodeWrapper.constructor()

    return dict
}
