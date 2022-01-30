import AppKit

let DOCK_BUNDLE_ID = "com.apple.dock"

public class Dock {
    public static func getApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: DOCK_BUNDLE_ID).first
    }

    public static func getPID() -> pid_t? {
        Self.getApp()?.processIdentifier
    }
}
