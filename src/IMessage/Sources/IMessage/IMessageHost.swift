import Foundation
import IMessageCore
import Logging

private let log = Logger(imessageLabel: "imessage")

/// Process-wide entry point.
///
/// The IMessage package is intentionally singleton-only within a process:
/// `Preferences` and `EventWatcherLifecycle.shared` are shared state and are
/// expected to be.
public enum IMessageHost {
    private static let bootstrapLock = NSLock()
    private static var didBootstrap = false

    public static var isNotificationsEnabledForMessages: Bool {
        Defaults.isNotificationsEnabledForApp(bundleID: messagesBundleID)
    }

    public static var useSecondaryInstanceEnvironment: Bool? {
        Preferences.useSecondaryInstanceEnvironment
    }

    public static var enabledExperiments: String {
        get { Preferences.enabledExperiments }
        set { Preferences.enabledExperiments = newValue }
    }

    public static var useSecondaryMessagesInstance: Bool {
        get { Preferences.useSecondaryMessagesInstance }
        set { Preferences.useSecondaryMessagesInstance = newValue }
    }

    public static var isLoggingEnabled: Bool {
        get { Preferences.isLoggingEnabled }
        set { Preferences.isLoggingEnabled = newValue }
    }

    public static var isHashingEnabled: Bool {
        get { Preferences.hashingEnabled }
    }

    public static func bootstrap() {
        bootstrapLock.lock()
        guard !didBootstrap else {
            bootstrapLock.unlock()
            return
        }
        didBootstrap = true
        bootstrapLock.unlock()

        // This needs to be ready by the first `debugLog` call, or else
        // subsequent calls to that function are dropped.
        LoggingSystem.bootstrap { identifier in
            IMessageLogHandler(identifier: identifier)
        }

        Task {
            // We trim as we log (within reason), but always try to do it on startup.
            try? await LogFileCoordinator.shared?.tryTrimming()
        }

        if let useSecondaryInstance = Preferences.useSecondaryInstanceEnvironment {
            Preferences.useSecondaryMessagesInstance = useSecondaryInstance
        }
        Preferences.configureHashing(defaultEnabled: true)

        let greeting = "howdy from IMessage!"
        if let system = System() {
            log.info("\(greeting) (\(system.os) \(system.kernelVersion) \(system.architecture), \(system.osVersion))")
        } else {
            log.info("\(greeting)")
        }

        Defaults.registerDefaults()

        Task { @MainActor in
            guard Defaults.imessage.bool(forKey: DefaultsKeys.settingsMenuItemInjection) else { return }

            if #available(macOS 13, *) {
                log.debug("trying to inject settings menu item whenever possible")
                MenuMaintainer.shared.add(maintaining: SettingsView.menuItem)
            } else {
                log.debug("couldn't inject settings menu item, macOS 13 or later is needed")
            }
        }
    }

    public static func bootstrapWithOptions(dataDirPath: String, verbose: Bool, useSecondaryInstance: Bool) {
        Preferences.setLoggingDirectory(dataDirPath)
        Preferences.setUseSecondaryInstance(useSecondaryInstance)
        Preferences.configureHashing(defaultEnabled: false)
        Preferences.isLoggingEnabled = verbose
        Log.consoleOutputEnabled = verbose
        Defaults.registerDefaults()

        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        LoggingSystem.bootstrap { identifier in
            IMessageLogHandler(
                identifier: identifier,
                logLevel: verbose ? .trace : .info
            )
        }

        Task {
            try? await LogFileCoordinator.shared?.tryTrimming()
        }
    }

    @available(*, deprecated, message: "Event watching runs for the PlatformAPI lifetime. Dispose the API to stop it.")
    public static func stopEventWatching() async {
    }

    public static var isEventWatching: Bool {
        EventWatcherLifecycle.shared.isWatching
    }

    public static func confirmUNCPrompt() async throws {
        try await Task.detached(priority: .background) {
            try PromptAutomation.confirmUNCPrompt()
        }.value
    }

    public static func disableMessagesNotifications() async throws {
        try await Task.detached(priority: .background) {
            _ = try PromptAutomation.disableNotificationsForApp(named: "Messages")
            Defaults.playSoundEffects = false
        }.value
    }

    public static func revealSettings() {
        Task {
            await revealSettingsForUserInteraction()
        }
    }

    public static func revealSettingsForUserInteraction() async {
        log.debug("told to reveal settings window")
        await MainActor.run {
            guard #available(macOS 13, *) else {
                log.error("can't reveal settings on macOS <13")
                return
            }
            log.debug("revealing settings window")
            SettingsWindowController.reveal()
        }
    }

    @MainActor
    public static var isSettingsWindowVisible: Bool {
        guard #available(macOS 13, *) else {
            return false
        }
        return SettingsWindowController.isVisible
    }
}
