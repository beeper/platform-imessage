import Foundation

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
