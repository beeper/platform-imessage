import Foundation

// Preference storage in this module is split across three backends:
//   1. `Preferences` (this enum) — in-memory toggles owned by Node module /
//      CLI bootstrap. Lost on process exit.
//   2. `Defaults.imessage` (UserDefaults) — durable user-tunable settings;
//      see Defaults.swift for keys.
//   3. `ProcessInfo.environment` — build/test escape hatches and CLI-set
//      values (IMESSAGE_LOGGING_DIR_PATH, IMESSAGE_USE_SECONDARY_INSTANCE,
//      IMESSAGE_STRIP_INTERNAL_FIELDS).
//
// When adding a setting, pick by lifecycle: process-only → here; durable user
// pref → Defaults; build/test toggle → environment.
enum Preferences {
    private static let stripInternalFieldsKey = "IMESSAGE_STRIP_INTERNAL_FIELDS"
    private static let loggingDirectoryKey = "IMESSAGE_LOGGING_DIR_PATH"
    private static let secondaryInstanceKey = "IMESSAGE_USE_SECONDARY_INSTANCE"

    static var isLoggingEnabled: Bool = false
    static var isPHTEnabled: Bool = false
    static var enabledExperiments: String = ""
    static var useSecondaryMessagesInstance: Bool = false

    static var stripInternalFields: Bool {
        ProcessInfo.processInfo.environment[stripInternalFieldsKey] == "1"
    }

    static var useSecondaryInstanceEnvironment: Bool {
        ProcessInfo.processInfo.environment[secondaryInstanceKey] != nil
    }

    static func applyCLIDefaults() {
        setDefault(stripInternalFieldsKey, value: "1")
    }

    static func setLoggingDirectory(_ path: String) {
        setenv(loggingDirectoryKey, path, 1)
    }

    static func setUseSecondaryInstance(_ enabled: Bool) {
        setenv(secondaryInstanceKey, enabled ? "1" : "0", 1)
        useSecondaryMessagesInstance = enabled
    }

    private static func setDefault(_ key: String, value: String) {
        guard ProcessInfo.processInfo.environment[key] == nil else { return }
        setenv(key, value, 0)
    }
}
