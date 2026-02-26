import NodeAPI
import Foundation
import WindowControl
import SwiftServerFoundation
import Logging
import IMDatabase

private let log = Logger(swiftServerLabel: "swift-server")

let messagesDir = try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    .appendingPathComponent("Messages", isDirectory: true)

#if DEBUG
@available(macOS 11, *)
extension MessagesControllerWrapper {
    @NodeMethod func _getMainWindow() {
        do {
            let window = try self.controller.elements.mainWindow
            Log.default.debug("@@@ [DEBUG] was able to fetch main window: \(window)")
        } catch {
            Log.default.error("@@@ [DEBUG] ❌ COULDN'T get main window! \(error)")
        }
    }
}
#endif

@available(macOS 10.15, *)
enum SysPrefsOnboarding {
    static var onboardingManager: OnboardingManager? = nil

    static func start() {
        guard onboardingManager == nil else { return }
        let onboardingManager = OnboardingManager()
        self.onboardingManager = onboardingManager
        onboardingManager.createWindow()
    }

    static func stop() {
        onboardingManager?.closeWindow()
        onboardingManager = nil
    }
}

enum Preferences {
    static var isLoggingEnabled = false
    static var isPHTEnabled = false
    static var enabledExperiments = ""
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
        try? await LogFileCoordinator.shared?.trim()
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
    var pollingTask: Task<Void, Never>?

    var dict: [String: NodePropertyConvertible] = try [
        "hashers": [
            "thread": try Hasher.thread.nodeValue(),
            "participant": try Hasher.participant.nodeValue(),
        ].nodeValue(),

        "appleInterfaceStyle": NodeProperty { _ in
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        },

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

        "cancelPollingIfNecessary": NodeFunction {
            defer { pollingTask = nil }
            if let pollingTask {
                log.info("was asked to cancel polling task, doing so")
                pollingTask.cancel()
            } else {
                log.warning("was asked to cancel polling task, but there isn't one; disregarding")
            }
            return
        },

        "startPolling": NodeFunction { (onEvent: NodeFunction, lastRowIDBig: NodeBigInt, lastDateReadNanosecondsBig: NodeBigInt) in
            if let task = pollingTask {
                log.warning("was asked to start polling, but there was already a poller alive; canceling it before proceeding")
                task.cancel()
                pollingTask = nil
            }

            let lastRowID = Int(try lastRowIDBig.signed().value)
            let lastDateRead = Date(nanosecondsSinceReferenceDate: Int(try lastDateReadNanosecondsBig.signed().value))
            log.debug("was asked to start polling (last row id: \(lastRowID), last date read: \(lastDateRead))")

            let poller = try Poller(serverEventSender: { events in
                var values = [any NodeValueConvertible]()
                // this probably isn't worth doing in parallel
                for event in events {
                    values.append(try await event.nodeValue())
                }
#if DEBUG
                log.debug("handing over \(values.count) value(s) to the event callback")
#endif
                try await onEvent.call([values])
            }, initialUpdatesCursor: Poller.MessageUpdatesCursor(lastRowID: lastRowID, lastDateRead: lastDateRead))

            pollingTask = Task {
                log.debug("going to poll forever")
                do {
                    try await poller.pollForever()
                } catch {
                    log.error("poller died: \(String(reflecting: error))")
                }
            }

            return // needed to resolve a compile-time type ambiguity apparently
        },

        "askForAutomationAccess": NodeFunction {
            let queue = try NodeAsyncQueue(label: "automation-access-callback")
            return try NodePromise { deferred in
                DispatchQueue.main.async {
                    let result = Result<NodeValueConvertible, Error> {
                        try OSA.promptAutomationAccess()
                        return undefined
                    }
                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "decodeAttributedString": NodeFunction { (data: Data) in
            guard let decoded = try? AttributedStringDecoder.decodeAttributedString(from: data) else {
                return undefined
            }
            return decoded.map { [
                "from": Double($0.scalarRange.lowerBound),
                "to": Double($0.scalarRange.upperBound),
                "text": "\($0.text)",
                "attributes": $0.attributes.mapValues { "\($0)" }
            ] }
        },

        "searchMessages": NodeFunction { (query: String, chatGUID: String?, mediaOnly: Bool?, sender: String?, limit: Int?) in
            let queue = try NodeAsyncQueue(label: "search-messages")
            return try NodePromise { deferred in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result<NodeValueConvertible, Error> {
                        let db = try IMDatabase()
                        let rowIDs = try db.searchMessages(
                            query: query,
                            chatGUID: chatGUID,
                            mediaOnly: mediaOnly ?? false,
                            sender: sender,
                            limit: limit ?? 20
                        )
                        return rowIDs as [NodeValueConvertible]
                    }
                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "confirmUNCPrompt": NodeFunction {
            let queue = try NodeAsyncQueue(label: "prompt-automation-callback")
            return try NodePromise { deferred in
                // we don't use DispatchQueue.main to prevent freezing the UI
                DispatchQueue.global(qos: .background).async {
                    let result = Result<NodeValueConvertible, Error> {
                        try PromptAutomation.confirmUNCPrompt()
                        return undefined
                    }
                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "disableNotificationsForApp": NodeFunction { (appName: String) in
            let queue = try NodeAsyncQueue(label: "prompt-automation-callback")
            return try NodePromise { deferred in
                // we don't use DispatchQueue.main to prevent freezing the UI
                DispatchQueue.global(qos: .background).async {
                    let result = Result<NodeValueConvertible, Error> {
                        try PromptAutomation.disableNotificationsForApp(named: appName)
                    }

                    try? queue.run {
                        try deferred(result)
                    }
                }
            }
        },

        "removeMessagesFromDock": NodeFunction {
            Defaults.removeAppFromDock(bundleID: messagesBundleID)
        },

        "killDock": NodeFunction {
            Dock.runningApplication()?.terminate()
        },

        "disableSoundEffects": NodeFunction {
            Defaults.playSoundEffects = false
        },

        "getDNDList": NodeFunction {
            guard let dict = Defaults.getDNDList() else {
                return undefined
            }
            let list = dict.compactMap { $0.value == Int(Date.distantFuture.timeIntervalSince1970) ? $0.key : nil }
            return list as [NodeValueConvertible]
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

    if #available(macOS 10.15, *) {
        dict["startSysPrefsOnboarding"] = try NodeFunction {
            SysPrefsOnboarding.start()
        }
        dict["stopSysPrefsOnboarding"] = try NodeFunction {
            SysPrefsOnboarding.stop()
        }
    }
    if #available(macOS 11, *) {
        dict["MessagesController"] = try MessagesControllerWrapper.constructor()
    }

    return dict
}
