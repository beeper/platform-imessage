import Foundation
import WindowControl
import IMessageCore
import Logging
import IMDatabase

private let log = Logger(imessageLabel: "imessage")

/// Process-wide entry point.
///
/// The IMessage package is intentionally singleton-only within a process:
/// `Preferences`, `accessManager`, and `PollingLifecycle.shared` are shared
/// state and are expected to be.
public enum IMessageHost {
    public typealias EventCallback = @Sendable ([PASEvent]) async throws -> Void
    public typealias SentryReporter = @Sendable (String) -> Void

    private static let accessManager = MessagesAccessManager()
    private static let bootstrapLock = NSLock()
    private static var didBootstrap = false

    public static var isMessagesAppInDock: Bool {
        Defaults.isAppInDock(bundleID: messagesBundleID)
    }

    public static var isNotificationsEnabledForMessages: Bool {
        Defaults.isNotificationsEnabledForApp(bundleID: messagesBundleID)
    }

    public static var useSecondaryInstanceEnvironment: Bool {
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

    public static var isPHTEnabled: Bool {
        get { Preferences.isPHTEnabled }
        set { Preferences.isPHTEnabled = newValue }
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
        Preferences.applyCLIDefaults()
        Preferences.setLoggingDirectory(dataDirPath)
        Preferences.setUseSecondaryInstance(useSecondaryInstance)
        Preferences.isLoggingEnabled = verbose
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

    public static func askForMessagesDirAccess() async throws {
        try await accessManager.requestAccess()
    }

    public static func canAccessMessagesDir() async throws -> Bool {
        try await DetachedWork.run {
            _ = try IMDatabase()
            return true
        }
    }

    public static func validateDatabaseAccess() async throws {
        try await DetachedWork.run {
            _ = try IMDatabase(createIndexes: true)
        }
    }

    public static func setEventCallback(
        _ onEvent: @escaping EventCallback,
        reportToSentry: SentryReporter? = nil
    ) {
        PollingLifecycle.shared.setEventCallback(onEvent, reportToSentry: reportToSentry)
    }

    public static func startPollingFromCurrentState() async throws {
        let (lastRowID, lastDateRead) = try await DetachedWork.run {
            let db = try IMDatabase()
            return (try db.lastMessageRowID(), try db.maxMessageDateRead())
        }
        try PollingLifecycle.shared.startPollingFromCurrentState(
            lastRowID: lastRowID,
            lastDateRead: lastDateRead
        )
    }

    public static func askForAutomationAccess() async throws {
        try await MainActor.run {
            try OSA.promptAutomationAccess()
        }
    }

    public static func confirmUNCPrompt() async throws {
        try await DetachedWork.run(priority: .background) {
            try PromptAutomation.confirmUNCPrompt()
        }
    }

    public static func disableMessagesNotifications() async throws {
        try await DetachedWork.run(priority: .background) {
            _ = try PromptAutomation.disableNotificationsForApp(named: "Messages")
            Defaults.playSoundEffects = false
        }
    }

    public static func removeMessagesFromDock() {
        Defaults.removeAppFromDock(bundleID: messagesBundleID)
    }

    public static func killDock() {
        Dock.runningApplication()?.terminate()
    }

    public static func revealSettings() {
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
    }

    public static func startSysPrefsOnboarding() {
        SysPrefsOnboarding.start()
    }

    public static func stopSysPrefsOnboarding() {
        SysPrefsOnboarding.stop()
    }
}
