import AppKit

struct ErrorMessage: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

public enum Dock {
    static let bundleID = "com.apple.dock"

    public static var pid: pid_t? {
        self.getApp()?.processIdentifier
    }

    public static func getApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Dock.bundleID).first
    }

    public class Observer {
        private let onExit: () -> Void

        public init(onExit: @escaping () -> Void) {
            self.onExit = onExit
            try? self.observe()
        }

        private func onDockTerminate() {
            debugLog("dock terminated")
            try? retry(withTimeout: 5, interval: 0.1) {
                guard Dock.getApp() != nil else { throw ErrorMessage("Dock not running") } // we wait for a max of 5s for dock to relaunch
                self.onExit()
                try? self.observe()
            }
        }

        private func observe() throws {
            try retry(withTimeout: 5, interval: 0.1) {
                guard Dock.getApp() != nil, let pid = Dock.pid else { throw ErrorMessage("Dock not running") }
                debugLog("observing dock exit with pid=\(pid)")
                try Process.monitorExit(pid: pid, self.onDockTerminate)
            }
        }

        // these don't work for Dock because Dock is a LSUIElement app
        // func registerNotifications() {
        //     let nc = NSWorkspace.shared.notificationCenter
        //     nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
        //                    object: nil,
        //                    queue: OperationQueue.main) { (notification: Notification) in
        //         debugLog("didLaunchApplicationNotification \(notification)")
        //     }
        //     nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
        //                    object: nil,
        //                    queue: OperationQueue.main) { (notification: Notification) in
        //         debugLog("didTerminateApplicationNotification \(notification)")
        //     }
        //     nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
        //                    object: nil,
        //                    queue: OperationQueue.main) { (notification: Notification) in
        //         debugLog("activeSpaceDidChangeNotification \(notification)")
        //     }
        // }

        // this doesn't work for unknown reasons
        // var token: NSKeyValueObservation?
        // func observe() throws {
        //     token?.invalidate()
        //     guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        //         debugLog("not observing because no app")
        //         return
        //     }
        //     // token =
        //     dock.observe(\.isTerminated, options: .new) { _, change in
        //         debugLog("dock isTerminated changed \(change)")
        //     }
        // }
        // deinit {
        //     debugLog("DockObserver deinit")
        //     token?.invalidate()
        // }
    }
}
