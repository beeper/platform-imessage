import Foundation

public enum PlatformEnvironment {
    private static let skipEagerMCKey = "IMESSAGE_SKIP_EAGER_MC"
    private static let stripInternalFieldsKey = "IMESSAGE_STRIP_INTERNAL_FIELDS"
    private static let loggingDirectoryKey = "IMESSAGE_LOGGING_DIR_PATH"
    private static let secondaryInstanceKey = "IMESSAGE_USE_SECONDARY_INSTANCE"

    static var stripInternalFields: Bool {
        ProcessInfo.processInfo.environment[stripInternalFieldsKey] == "1"
    }

    public static var useSecondaryInstance: Bool {
        ProcessInfo.processInfo.environment[secondaryInstanceKey] != nil
    }

    static func applyCLIDefaults() {
        setDefault(skipEagerMCKey, value: "1")
        setDefault(stripInternalFieldsKey, value: "1")
    }

    static func setLoggingDirectory(_ path: String) {
        setenv(loggingDirectoryKey, path, 1)
    }

    static func setUseSecondaryInstance(_ enabled: Bool) {
        setenv(secondaryInstanceKey, enabled ? "1" : "0", 1)
        Preferences.useSecondaryMessagesInstance = enabled
    }

    private static func setDefault(_ key: String, value: String) {
        guard ProcessInfo.processInfo.environment[key] == nil else { return }
        setenv(key, value, 0)
    }
}
