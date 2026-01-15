import Foundation
import AppKit
import LSLauncher

// MARK: - App Info Structure

struct AppInfo {
    let name: String
    let bundleIdentifier: String
    let url: URL

    var isRunning: Bool {
        NSRunningApplication.isRunning(bundleIdentifier: bundleIdentifier)
    }

    var runningInstances: [NSRunningApplication] {
        NSRunningApplication.instances(withBundleIdentifier: bundleIdentifier)
    }
}

// MARK: - Interactive CLI

class InteractiveCLI {
    let launcher = LSApplicationLauncher.shared
    let observer = LSTypeObserver()
    var installedApps: [AppInfo] = []
    var selectedApp: AppInfo?
    var isObserving = false

    func run() {
        print("\n\u{001B}[1;36m+============================================================+\u{001B}[0m")
        print("\u{001B}[1;36m|              LSLauncher Interactive CLI                    |\u{001B}[0m")
        print("\u{001B}[1;36m+============================================================+\u{001B}[0m\n")

        loadInstalledApps()

        while true {
            printMainMenu()

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
                continue
            }

            switch input {
            case "1": selectApp()
            case "2": launchSelectedApp()
            case "3": launchAsUIElement()
            case "4": launchInBackground()
            case "5": launchSynchronously()
            case "6": listRunningInstances()
            case "7": killInstance()
            case "8": promoteToForeground()
            case "9": demoteToUIElement()
            case "10": demoteToBackground()
            case "11": runTimingComparison()
            case "12": showAllRunningApps()
            case "13": openURLInApp()
            case "14": lockAppToUIElement()
            case "15": toggleTypeObserver()
            case "16": toggleAutoSuppress()
            case "17": showAutoSuppressList()
            case "q", "quit", "exit":
                observer.stopObserving()
                print("\n\u{001B}[1;33mGoodbye!\u{001B}[0m\n")
                return
            default:
                print("\u{001B}[1;31mInvalid option. Please try again.\u{001B}[0m")
            }
        }
    }

    func loadInstalledApps() {
        print("\u{001B}[33mLoading installed applications...\u{001B}[0m")

        let appDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        var apps: [AppInfo] = []

        for dir in appDirs {
            let url = URL(fileURLWithPath: dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                continue
            }

            for item in contents where item.pathExtension == "app" {
                if let bundle = Bundle(url: item),
                   let bundleID = bundle.bundleIdentifier,
                   let name = bundle.infoDictionary?["CFBundleName"] as? String ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? item.deletingPathExtension().lastPathComponent as String? {
                    apps.append(AppInfo(name: name, bundleIdentifier: bundleID, url: item))
                }
            }
        }

        installedApps = apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
        print("\u{001B}[32mLoaded \(installedApps.count) applications.\u{001B}[0m\n")
    }

    func printMainMenu() {
        print("\n\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        if let app = selectedApp {
            let status = app.isRunning ? "\u{001B}[32m* Running (\(app.runningInstances.count))\u{001B}[0m" : "\u{001B}[90mo Not running\u{001B}[0m"
            print("\u{001B}[1mSelected App:\u{001B}[0m \u{001B}[1;33m\(app.name)\u{001B}[0m \(status)")
            print("\u{001B}[90m             \(app.bundleIdentifier)\u{001B}[0m")
        } else {
            print("\u{001B}[1mSelected App:\u{001B}[0m \u{001B}[90mNone - press 1 to select\u{001B}[0m")
        }
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[1]\u{001B}[0m  Select Application")
        print("\u{001B}[1;36m[2]\u{001B}[0m  Launch (Normal)")
        print("\u{001B}[1;36m[3]\u{001B}[0m  Launch as UIElement (no dock icon)")
        print("\u{001B}[1;36m[4]\u{001B}[0m  Launch in Background")
        print("\u{001B}[1;36m[5]\u{001B}[0m  Launch Synchronously (timing test)")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[6]\u{001B}[0m  List Running Instances")
        print("\u{001B}[1;36m[7]\u{001B}[0m  Kill Instance")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[8]\u{001B}[0m  Promote to Foreground (show in dock)")
        print("\u{001B}[1;36m[9]\u{001B}[0m  Demote to UIElement (hide from dock)")
        print("\u{001B}[1;36m[10]\u{001B}[0m Demote to Background")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[11]\u{001B}[0m Run NSWorkspace vs LSLauncher Timing Test")
        print("\u{001B}[1;36m[12]\u{001B}[0m Show All Running Applications")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[13]\u{001B}[0m Open URL in Running App (via ASN)")
        print("\u{001B}[1;36m[14]\u{001B}[0m Lock App to UIElement (prevent foreground)")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        let observerStatus = isObserving ? "\u{001B}[32mON\u{001B}[0m" : "\u{001B}[90mOFF\u{001B}[0m"
        print("\u{001B}[1;36m[15]\u{001B}[0m Toggle Type Observer [\(observerStatus)]")
        print("\u{001B}[1;36m[16]\u{001B}[0m Toggle Auto-Suppress for Selected App")
        print("\u{001B}[1;36m[17]\u{001B}[0m Show Auto-Suppress List")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[q]\u{001B}[0m  Quit")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")
    }

    func selectApp() {
        print("\n\u{001B}[1mSearch for an app (or press Enter to browse):\u{001B}[0m ", terminator: "")
        guard let search = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let filtered: [AppInfo]
        if search.isEmpty {
            filtered = installedApps
        } else {
            filtered = installedApps.filter {
                $0.name.lowercased().contains(search.lowercased()) ||
                $0.bundleIdentifier.lowercased().contains(search.lowercased())
            }
        }

        if filtered.isEmpty {
            print("\u{001B}[31mNo apps found matching '\(search)'\u{001B}[0m")
            return
        }

        let pageSize = 15
        var page = 0
        let totalPages = (filtered.count + pageSize - 1) / pageSize

        while true {
            print("\n\u{001B}[1mApplications (Page \(page + 1)/\(totalPages)):\u{001B}[0m")
            print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")

            let start = page * pageSize
            let end = min(start + pageSize, filtered.count)

            for (idx, app) in filtered[start..<end].enumerated() {
                let num = String(format: "%2d", idx + 1)
                let status = app.isRunning ? "\u{001B}[32m*\u{001B}[0m" : "\u{001B}[90mo\u{001B}[0m"
                print("\u{001B}[1;36m[\(num)]\u{001B}[0m \(status) \(app.name)")
                print("     \u{001B}[90m\(app.bundleIdentifier)\u{001B}[0m")
            }

            print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")
            print("\u{001B}[90m[n]ext  [p]rev  [number] to select  [q]uit\u{001B}[0m")
            print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { continue }

            if input == "n" && page < totalPages - 1 {
                page += 1
            } else if input == "p" && page > 0 {
                page -= 1
            } else if input == "q" {
                return
            } else if let num = Int(input), num >= 1 && num <= (end - start) {
                selectedApp = filtered[start + num - 1]
                print("\n\u{001B}[32m> Selected: \(selectedApp!.name)\u{001B}[0m")
                return
            }
        }
    }

    func launchSelectedApp() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[33mLaunching \(app.name)...\u{001B}[0m")

        do {
            let result = try launcher.launch(at: app.url, configuration: .default)
            print("\u{001B}[32m> Launched successfully in \(String(format: "%.3f", result.launchDuration))s\u{001B}[0m")
            print("  PID: \(result.application.processIdentifier)")
            print("  isFinishedLaunching: \(result.isFinishedLaunching)")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func launchAsUIElement() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[33mLaunching \(app.name) as UIElement (no dock icon)...\u{001B}[0m")

        var config = LaunchConfiguration.uiElement
        config.preferRunningInstance = false

        do {
            let result = try launcher.launch(at: app.url, configuration: config)
            print("\u{001B}[32m> Launched as UIElement in \(String(format: "%.3f", result.launchDuration))s\u{001B}[0m")
            print("  PID: \(result.application.processIdentifier)")
            if let mode = result.application.applicationMode {
                print("  Mode: \(mode.rawValue)")
            }
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func launchInBackground() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[33mLaunching \(app.name) in background...\u{001B}[0m")

        var config = LaunchConfiguration.background
        config.preferRunningInstance = false

        do {
            let result = try launcher.launch(at: app.url, configuration: config)
            print("\u{001B}[32m> Launched in background in \(String(format: "%.3f", result.launchDuration))s\u{001B}[0m")
            print("  PID: \(result.application.processIdentifier)")
            if let mode = result.application.applicationMode {
                print("  Mode: \(mode.rawValue)")
            }
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func launchSynchronously() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        // First kill any running instances
        for instance in app.runningInstances {
            instance.terminate()
        }
        Thread.sleep(forTimeInterval: 1.0)

        print("\n\u{001B}[33mLaunching \(app.name) synchronously (blocking until ready)...\u{001B}[0m")

        do {
            let result = try launcher.launch(at: app.url, configuration: .synchronous)
            print("\u{001B}[32m> Launched synchronously in \(String(format: "%.3f", result.launchDuration))s\u{001B}[0m")
            print("  PID: \(result.application.processIdentifier)")
            print("  isFinishedLaunching: \(result.isFinishedLaunching)")

            let queryable = NSRunningApplication.isRunning(bundleIdentifier: app.bundleIdentifier)
            print("  Queryable via NSRunningApplication: \(queryable ? "> Yes" : "x No")")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func listRunningInstances() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name)\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mRunning instances of \(app.name):\u{001B}[0m")
        print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")

        for (idx, instance) in instances.enumerated() {
            let mode = instance.applicationMode?.rawValue ?? "Unknown"
            let modeColor: String
            switch mode {
            case "Foreground": modeColor = "\u{001B}[32m"
            case "UIElement": modeColor = "\u{001B}[33m"
            case "BackgroundOnly": modeColor = "\u{001B}[90m"
            default: modeColor = "\u{001B}[37m"
            }

            print("\u{001B}[1;36m[\(idx + 1)]\u{001B}[0m PID: \(instance.processIdentifier)")
            print("    Mode: \(modeColor)\(mode)\u{001B}[0m")
            print("    isFinishedLaunching: \(instance.isFinishedLaunching)")
            print("    isHidden: \(instance.isHidden)")
            print("    isActive: \(instance.isActive)")
        }
    }

    func killInstance() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name)\u{001B}[0m")
            return
        }

        if instances.count == 1 {
            print("\n\u{001B}[33mKilling \(app.name) (PID: \(instances[0].processIdentifier))...\u{001B}[0m")
            instances[0].terminate()
            print("\u{001B}[32m> Terminated\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mSelect instance to kill:\u{001B}[0m")
        for (idx, instance) in instances.enumerated() {
            let mode = instance.applicationMode?.rawValue ?? "Unknown"
            print("\u{001B}[1;36m[\(idx + 1)]\u{001B}[0m PID: \(instance.processIdentifier) (\(mode))")
        }
        print("\u{001B}[1;36m[a]\u{001B}[0m Kill all")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return }

        if input == "a" {
            for instance in instances {
                instance.terminate()
            }
            print("\u{001B}[32m> Terminated all \(instances.count) instances\u{001B}[0m")
        } else if let num = Int(input), num >= 1 && num <= instances.count {
            instances[num - 1].terminate()
            print("\u{001B}[32m> Terminated instance with PID \(instances[num - 1].processIdentifier)\u{001B}[0m")
        }
    }

    func promoteToForeground() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name)\u{001B}[0m")
            return
        }

        let instance = selectInstance(from: instances, action: "promote to Foreground")
        guard let inst = instance else { return }

        do {
            try inst.promote()
            print("\u{001B}[32m> Promoted to Foreground (now visible in dock)\u{001B}[0m")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func demoteToUIElement() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name)\u{001B}[0m")
            return
        }

        let instance = selectInstance(from: instances, action: "demote to UIElement")
        guard let inst = instance else { return }

        do {
            try inst.suppress()
            print("\u{001B}[32m> Demoted to UIElement (hidden from dock)\u{001B}[0m")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func demoteToBackground() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name)\u{001B}[0m")
            return
        }

        let instance = selectInstance(from: instances, action: "demote to Background")
        guard let inst = instance else { return }

        do {
            try inst.suppressToBackground()
            print("\u{001B}[32m> Demoted to Background\u{001B}[0m")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func selectInstance(from instances: [NSRunningApplication], action: String) -> NSRunningApplication? {
        if instances.count == 1 {
            return instances[0]
        }

        print("\n\u{001B}[1mSelect instance to \(action):\u{001B}[0m")
        for (idx, instance) in instances.enumerated() {
            let mode = instance.applicationMode?.rawValue ?? "Unknown"
            print("\u{001B}[1;36m[\(idx + 1)]\u{001B}[0m PID: \(instance.processIdentifier) (\(mode))")
        }
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let num = Int(input), num >= 1 && num <= instances.count else {
            return nil
        }

        return instances[num - 1]
    }

    func runTimingComparison() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[1;35m         NSWorkspace vs LSApplicationLauncher Timing Test       \u{001B}[0m")
        print("\u{001B}[1;35m===============================================================\u{001B}[0m")

        // Kill all instances first
        print("\n\u{001B}[33mTerminating any running instances...\u{001B}[0m")
        for instance in app.runningInstances {
            instance.terminate()
        }
        Thread.sleep(forTimeInterval: 1.5)

        // Test 1: NSWorkspace
        print("\n\u{001B}[1m[Test 1] NSWorkspace.openApplication (closure-based):\u{001B}[0m")

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        var nsWorkspaceReturnTime: TimeInterval = 0
        nonisolated(unsafe) var nsWorkspaceFinishedAtReturn = false
        var nsWorkspaceWaitTime: TimeInterval = 0

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var nsApp: NSRunningApplication?

        let nsStartTime = Date()
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { runningApp, _ in
            nsApp = runningApp
            nsWorkspaceFinishedAtReturn = runningApp?.isFinishedLaunching ?? false
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        nsWorkspaceReturnTime = Date().timeIntervalSince(nsStartTime)

        if let runningApp = nsApp, !runningApp.isFinishedLaunching {
            let waitStart = Date()
            while !runningApp.isFinishedLaunching && Date().timeIntervalSince(waitStart) < 10 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            nsWorkspaceWaitTime = Date().timeIntervalSince(waitStart)
        }

        print("  Time to return:          \u{001B}[1;33m\(String(format: "%.3f", nsWorkspaceReturnTime))s\u{001B}[0m")
        print("  isFinishedLaunching:     \(nsWorkspaceFinishedAtReturn ? "\u{001B}[32mtrue\u{001B}[0m" : "\u{001B}[31mfalse\u{001B}[0m")")
        print("  Additional wait needed:  \(String(format: "%.3f", nsWorkspaceWaitTime))s")

        nsApp?.terminate()
        Thread.sleep(forTimeInterval: 1.5)

        // Test 2: LSApplicationLauncher
        print("\n\u{001B}[1m[Test 2] LSApplicationLauncher.launch(synchronous):\u{001B}[0m")

        var lsReturnTime: TimeInterval = 0
        var lsFinishedAtReturn = false
        var lsWaitTime: TimeInterval = 0

        do {
            let result = try launcher.launch(at: app.url, configuration: .synchronous)
            lsReturnTime = result.launchDuration
            lsFinishedAtReturn = result.isFinishedLaunching

            if !result.isFinishedLaunching {
                let waitStart = Date()
                while !result.application.isFinishedLaunching && Date().timeIntervalSince(waitStart) < 10 {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                }
                lsWaitTime = Date().timeIntervalSince(waitStart)
            }
            result.application.terminate()
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
            return
        }

        print("  Time to return:          \u{001B}[1;33m\(String(format: "%.3f", lsReturnTime))s\u{001B}[0m")
        print("  isFinishedLaunching:     \(lsFinishedAtReturn ? "\u{001B}[32mtrue\u{001B}[0m" : "\u{001B}[31mfalse\u{001B}[0m")")
        print("  Additional wait needed:  \(String(format: "%.3f", lsWaitTime))s")

        // Summary
        print("\n\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1m                           SUMMARY                              \u{001B}[0m")
        print("\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")
        print("                          NSWorkspace    LSLauncher")
        print("  Time to return:         \(String(format: "%7.3f", nsWorkspaceReturnTime))s       \(String(format: "%7.3f", lsReturnTime))s")
        print("  Ready at return:        \(nsWorkspaceFinishedAtReturn ? "   Yes  " : "   No   ")       \(lsFinishedAtReturn ? "   Yes  " : "   No   ")")
        print("  Total time to ready:    \(String(format: "%7.3f", nsWorkspaceReturnTime + nsWorkspaceWaitTime))s       \(String(format: "%7.3f", lsReturnTime + lsWaitTime))s")
        print("\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")

        if nsWorkspaceReturnTime < lsReturnTime {
            print("\n\u{001B}[33m>  NSWorkspace returned \(String(format: "%.3f", lsReturnTime - nsWorkspaceReturnTime))s faster\u{001B}[0m")
        }

        if !nsWorkspaceFinishedAtReturn && lsFinishedAtReturn {
            print("\u{001B}[32m> LSApplicationLauncher is truly synchronous!\u{001B}[0m")
            print("\u{001B}[90m  NSWorkspace returns before app is ready, LSLauncher waits.\u{001B}[0m")
        }
    }

    func showAllRunningApps() {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        print("\n\u{001B}[1mAll Running Applications (\(runningApps.count)):\u{001B}[0m")
        print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")

        for app in runningApps {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let modeColor: String
            switch mode {
            case "Foreground": modeColor = "\u{001B}[32m"
            case "UIElement": modeColor = "\u{001B}[33m"
            case "BackgroundOnly": modeColor = "\u{001B}[90m"
            default: modeColor = "\u{001B}[37m"
            }

            let name = app.localizedName ?? "Unknown"
            print("\(modeColor)*\u{001B}[0m \(name)")
            print("  \u{001B}[90mPID: \(app.processIdentifier) | Mode: \(modeColor)\(mode)\u{001B}[0m")
        }
    }

    func openURLInApp() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mEnter URL to open (or press Enter for default test URL):\u{001B}[0m ", terminator: "")
        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let urlString: String
        if urlInput.isEmpty {
            // Use a sensible default based on the app
            if app.bundleIdentifier.contains("Messages") || app.bundleIdentifier.contains("messages") {
                urlString = "imessage://+15551234567"
            } else if app.bundleIdentifier.contains("Safari") || app.bundleIdentifier.contains("safari") {
                urlString = "https://apple.com"
            } else if app.bundleIdentifier.contains("Mail") || app.bundleIdentifier.contains("mail") {
                urlString = "mailto:test@example.com"
            } else {
                urlString = "https://apple.com"
            }
            print("\u{001B}[90mUsing default URL: \(urlString)\u{001B}[0m")
        } else {
            urlString = urlInput
        }

        guard let url = URL(string: urlString) else {
            print("\u{001B}[31mInvalid URL: \(urlString)\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mActivate (bring to front) the app? [y/N]:\u{001B}[0m ", terminator: "")
        let activateInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "n"
        let activate = activateInput == "y" || activateInput == "yes"

        let instance: NSRunningApplication
        if instances.count == 1 {
            instance = instances[0]
        } else {
            guard let selected = selectInstance(from: instances, action: "open URL in") else { return }
            instance = selected
        }

        print("\n\u{001B}[33mSending URL via Apple Events (GURL) directly to process...\u{001B}[0m")
        print("  Target: \(app.name) (PID: \(instance.processIdentifier))")
        print("  URL: \(url)")
        print("  Activate: \(activate)")

        // Use Apple Events to send directly to the target process
        // This bypasses LaunchServices URL scheme handler resolution
        let status = launcher.sendURL(url, to: instance)

        if status == noErr {
            print("\u{001B}[32m> Apple Event sent successfully (status: \(status))\u{001B}[0m")

            // Optionally activate the app
            if activate {
                instance.activate()
            }

            // Check the app mode after a short delay
            Thread.sleep(forTimeInterval: 0.5)
            if let newMode = instance.applicationMode {
                print("  Current mode: \(newMode.rawValue)")
            }
        } else {
            print("\u{001B}[31m> Failed with OSStatus: \(status)\u{001B}[0m")

            // Provide some common error explanations
            switch status {
            case -600:
                print("  \u{001B}[90m(procNotFound - process not found)\u{001B}[0m")
            case -903:
                print("  \u{001B}[90m(noPortErr - can't find target port)\u{001B}[0m")
            case -905:
                print("  \u{001B}[90m(destPortErr - destination port error)\u{001B}[0m")
            case -1712:
                print("  \u{001B}[90m(errAEEventNotPermitted - event not permitted by sandbox)\u{001B}[0m")
            default:
                break
            }
        }
    }

    func lockAppToUIElement() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance: NSRunningApplication
        if instances.count == 1 {
            instance = instances[0]
        } else {
            guard let selected = selectInstance(from: instances, action: "lock to UIElement") else { return }
            instance = selected
        }

        print("\n\u{001B}[33mLocking \(app.name) to UIElement mode...\u{001B}[0m")
        print("  This sets both kLSApplicationTypeKey AND kLSApplicationTypeToRestoreKey")
        print("  The app should not be able to promote itself back to foreground")

        do {
            try launcher.lockToUIElement(instance)
            print("\u{001B}[32m> Locked to UIElement successfully\u{001B}[0m")

            // Verify the change
            Thread.sleep(forTimeInterval: 0.3)
            if let mode = instance.applicationMode {
                print("  Current mode: \(mode.rawValue)")
            }

            print("\n\u{001B}[90mTry opening a deep link now - the app should stay hidden.\u{001B}[0m")
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    // MARK: - Type Observer

    func toggleTypeObserver() {
        if isObserving {
            observer.stopObserving()
            isObserving = false
            print("\n\u{001B}[33mType observer stopped.\u{001B}[0m")
        } else {
            print("\n\u{001B}[33mStarting type observer...\u{001B}[0m")
            print("\u{001B}[90mYou will see notifications when any app changes its type.\u{001B}[0m\n")

            observer.startObserving { [weak self] bundleID, pid, oldType, newType in
                let bundle = bundleID ?? "Unknown"
                let old = oldType?.rawValue ?? "nil"
                let new = newType?.rawValue ?? "nil"

                let timestamp = self?.formatTimestamp() ?? ""
                print("\n\u{001B}[1;35m[\(timestamp)] TYPE CHANGE:\u{001B}[0m \(bundle) (PID: \(pid))")
                print("  \u{001B}[90m\(old)\u{001B}[0m -> \u{001B}[1;33m\(new)\u{001B}[0m")

                // Check if this app is being auto-suppressed
                if let bundleID = bundleID, self?.observer.isAutoSuppressing(bundleID: bundleID) == true {
                    if newType != .uiElement {
                        print("  \u{001B}[36m(auto-suppressing to UIElement)\u{001B}[0m")
                    }
                }
                print("")
            }

            isObserving = true
            print("\u{001B}[32mType observer started.\u{001B}[0m")
        }
    }

    func toggleAutoSuppress() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        if observer.isAutoSuppressing(bundleID: app.bundleIdentifier) {
            observer.removeAutoSuppress(bundleID: app.bundleIdentifier)
            print("\n\u{001B}[33mAuto-suppress disabled for \(app.name)\u{001B}[0m")
        } else {
            observer.addAutoSuppress(bundleID: app.bundleIdentifier)
            print("\n\u{001B}[32mAuto-suppress enabled for \(app.name)\u{001B}[0m")
            print("\u{001B}[90mThe app will be automatically suppressed to UIElement whenever it tries to become foreground.\u{001B}[0m")

            // Make sure observer is running
            if !isObserving {
                print("\u{001B}[90mNote: Starting type observer to enable auto-suppress...\u{001B}[0m")
                toggleTypeObserver()
            }
        }
    }

    func showAutoSuppressList() {
        let bundleIDs = observer.autoSuppressedBundleIDs

        if bundleIDs.isEmpty {
            print("\n\u{001B}[33mNo apps are being auto-suppressed.\u{001B}[0m")
            print("\u{001B}[90mUse option 16 to add apps to the auto-suppress list.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mAuto-Suppressed Apps (\(bundleIDs.count)):\u{001B}[0m")
        print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")

        for bundleID in bundleIDs.sorted() {
            let isRunning = NSRunningApplication.isRunning(bundleIdentifier: bundleID)
            let status = isRunning ? "\u{001B}[32m* Running\u{001B}[0m" : "\u{001B}[90mo Not running\u{001B}[0m"

            // Try to find the app name
            var appName = bundleID
            if let app = installedApps.first(where: { $0.bundleIdentifier == bundleID }) {
                appName = app.name
            }

            print("\u{001B}[1;33m\(appName)\u{001B}[0m \(status)")
            print("  \u{001B}[90m\(bundleID)\u{001B}[0m")

            // Show current mode if running
            if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let mode = runningApp.applicationMode {
                let modeColor: String
                switch mode {
                case .foreground: modeColor = "\u{001B}[32m"
                case .uiElement: modeColor = "\u{001B}[33m"
                case .backgroundOnly: modeColor = "\u{001B}[90m"
                }
                print("  Current mode: \(modeColor)\(mode.rawValue)\u{001B}[0m")
            }
        }
    }

    func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

// MARK: - Main Entry Point

let cli = InteractiveCLI()
cli.run()
