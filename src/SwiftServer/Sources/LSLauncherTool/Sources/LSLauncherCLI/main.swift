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
    var installedApps: [AppInfo] = []
    var selectedApp: AppInfo?

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
            case "15": openURLSuppressed()
            case "16": testSuppressionMethods()
            case "17": togglePostLaunchBringForward()
            case "18": showSessionFlags()
            case "19": blockFromFrontSkyLight()
            case "20": allowToFrontSkyLight()
            case "21": removeFromPermittedFrontASNs()
            case "22": runSkyLightTest()
            case "23": openURLWithWatchdog()
            case "24": toggleWatchdog()
            case "q", "quit", "exit":
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
        print("\u{001B}[1;33m         FOREGROUND SUPPRESSION EXPERIMENTS                  \u{001B}[0m")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[15]\u{001B}[0m Open URL Suppressed (full options)")
        print("\u{001B}[1;36m[16]\u{001B}[0m Test All Suppression Methods")
        print("\u{001B}[1;36m[17]\u{001B}[0m Toggle Post-Launch Bring Forward Flag")
        print("\u{001B}[1;36m[18]\u{001B}[0m Show Session Flags")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;31m         SKYLIGHT (NUCLEAR) OPTIONS                          \u{001B}[0m")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[19]\u{001B}[0m Block from Front (SkyLight)")
        print("\u{001B}[1;36m[20]\u{001B}[0m Allow to Front (SkyLight)")
        print("\u{001B}[1;36m[21]\u{001B}[0m Remove from Permitted Front ASNs")
        print("\u{001B}[1;36m[22]\u{001B}[0m Run SkyLight Test (block + URL + check)")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;32m         MODE WATCHDOG (CONTINUOUS RESET)                    \u{001B}[0m")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1;36m[23]\u{001B}[0m Open URL with Watchdog (auto-reset mode)")
        print("\u{001B}[1;36m[24]\u{001B}[0m Toggle Watchdog (start/stop)")
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
                urlString = "imessage://test"
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

        print("\n\u{001B}[33mOpening URL via _LSOpenURLsUsingASNWithCompletionHandler...\u{001B}[0m")
        print("  Target: \(app.name) (PID: \(instance.processIdentifier))")
        print("  URL: \(url)")
        print("  Activate: \(activate)")

        do {
            try launcher.openURLs([url], in: instance, activate: activate)
            print("\u{001B}[32m> URL dispatch sent successfully\u{001B}[0m")

            // Check if the app mode changed after a short delay
            Thread.sleep(forTimeInterval: 0.5)
            if let newMode = instance.applicationMode {
                print("  Current mode: \(newMode.rawValue)")
            }
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
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

    // MARK: - Foreground Suppression Experiments

    func openURLSuppressed() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mEnter URL to open (or press Enter for default):\u{001B}[0m ", terminator: "")
        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let urlString = urlInput.isEmpty ? getDefaultURL(for: app) : urlInput
        print("\u{001B}[90mUsing URL: \(urlString)\u{001B}[0m")

        guard let url = URL(string: urlString) else {
            print("\u{001B}[31mInvalid URL: \(urlString)\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "open URL in")
        guard let inst = instance else { return }

        print("\n\u{001B}[1mSelect suppression options:\u{001B}[0m")
        print("\u{001B}[1;36m[1]\u{001B}[0m Minimal (noActivate only)")
        print("\u{001B}[1;36m[2]\u{001B}[0m Standard (activate + notUserAction + noForeground)")
        print("\u{001B}[1;36m[3]\u{001B}[0m Strong (+ launch modifiers)")
        print("\u{001B}[1;36m[4]\u{001B}[0m Maximum (+ session flag + lock UIElement)")
        print("\u{001B}[1;36m[5]\u{001B}[0m Custom (select individual options)")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        var options: ForegroundSuppressionOptions

        switch choice {
        case "1": options = .minimal
        case "2": options = .standard
        case "3": options = .strong
        case "4": options = .maximum
        case "5": options = selectCustomOptions()
        default:
            print("\u{001B}[31mInvalid choice\u{001B}[0m")
            return
        }

        print("\n\u{001B}[33mOpening URL with suppression options: \(options)\u{001B}[0m")

        // Capture state before
        let modeBefore = inst.applicationMode?.rawValue ?? "Unknown"
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let wasFrontBefore = frontBefore?.processIdentifier == inst.processIdentifier

        print("  Before: mode=\(modeBefore), isFront=\(wasFrontBefore)")

        do {
            let tester = ForegroundSuppressionTester.shared
            let result = try tester.openURL(url, in: inst, options: options)

            print("\n\u{001B}[1mResult:\u{001B}[0m")
            print("  Dispatched: \(result.dispatched)")
            print("  Mode before: \(result.modeBeforeOpen?.rawValue ?? "?")")
            print("  Mode after: \(result.modeAfterOpen?.rawValue ?? "?")")
            print("  Was front before: \(result.wasFrontmostBefore)")
            print("  Became front: \(result.becameFrontmost)")

            if result.suppressionEffective {
                print("\n\u{001B}[32m✓ SUPPRESSION EFFECTIVE - App did NOT come to foreground!\u{001B}[0m")
            } else {
                print("\n\u{001B}[31m✗ SUPPRESSION FAILED - App came to foreground\u{001B}[0m")
            }
        } catch {
            print("\u{001B}[31m> Failed: \(error.localizedDescription)\u{001B}[0m")
        }
    }

    func selectCustomOptions() -> ForegroundSuppressionOptions {
        var options: ForegroundSuppressionOptions = []

        let allOptions: [(String, ForegroundSuppressionOptions)] = [
            ("noActivate", .noActivate),
            ("notUserAction", .notUserAction),
            ("uiElementLaunch", .uiElementLaunch),
            ("noForegroundLaunch", .noForegroundLaunch),
            ("doNotBringFrontmost", .doNotBringFrontmost),
            ("noWindowBringForward", .noWindowBringForward),
            ("disablePostLaunchBringForward", .disablePostLaunchBringForward),
            ("lockToUIElement", .lockToUIElement),
            ("hide", .hide),
        ]

        print("\n\u{001B}[1mSelect options (space-separated numbers, e.g., '1 2 5'):\u{001B}[0m")
        for (idx, (name, _)) in allOptions.enumerated() {
            print("\u{001B}[1;36m[\(idx + 1)]\u{001B}[0m \(name)")
        }
        print("\u{001B}[1mChoices:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else { return options }

        let selections = input.split(separator: " ").compactMap { Int($0) }
        for num in selections {
            if num >= 1 && num <= allOptions.count {
                options.insert(allOptions[num - 1].1)
            }
        }

        return options
    }

    func testSuppressionMethods() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "test suppression on")
        guard let inst = instance else { return }

        print("\n\u{001B}[1mEnter test URL (or press Enter for default):\u{001B}[0m ", terminator: "")
        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let urlString = urlInput.isEmpty ? getDefaultURL(for: app) : urlInput
        guard let url = URL(string: urlString) else {
            print("\u{001B}[31mInvalid URL\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[1;35m          FOREGROUND SUPPRESSION COMPREHENSIVE TEST            \u{001B}[0m")
        print("\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[90mApp: \(app.name) (PID: \(inst.processIdentifier))\u{001B}[0m")
        print("\u{001B}[90mURL: \(url)\u{001B}[0m")
        print("")

        let testCases: [(String, ForegroundSuppressionOptions)] = [
            ("Baseline (no suppression)", []),
            ("Minimal (noActivate)", .minimal),
            ("Standard", .standard),
            ("Strong (+ modifiers)", .strong),
            ("Lock UIElement only", [.lockToUIElement]),
            ("Session flag only", [.disablePostLaunchBringForward]),
            ("Maximum", .maximum),
        ]

        let tester = ForegroundSuppressionTester.shared

        print("\u{001B}[1mTest                              Mode→Mode   Front?  Result\u{001B}[0m")
        print("\u{001B}[90m---------------------------------------------------------------\u{001B}[0m")

        for (name, options) in testCases {
            // Reset to UIElement between tests
            try? launcher.lockToUIElement(inst)
            Thread.sleep(forTimeInterval: 0.3)

            // Click away to ensure app isn't front
            // (This simulates user being in another app)

            do {
                let result = try tester.openURL(url, in: inst, options: options, waitTime: 0.5)

                let modeBefore = result.modeBeforeOpen?.rawValue.prefix(3) ?? "?"
                let modeAfter = result.modeAfterOpen?.rawValue.prefix(3) ?? "?"
                let frontStatus = result.becameFrontmost ? "\u{001B}[31mYES\u{001B}[0m" : "\u{001B}[32mno\u{001B}[0m"
                let resultStatus = result.suppressionEffective ? "\u{001B}[32m✓ OK\u{001B}[0m" : "\u{001B}[31m✗ FAIL\u{001B}[0m"

                let paddedName = name.padding(toLength: 32, withPad: " ", startingAt: 0)
                print("\(paddedName)  \(modeBefore)→\(modeAfter)     \(frontStatus)   \(resultStatus)")

            } catch {
                let paddedName = name.padding(toLength: 32, withPad: " ", startingAt: 0)
                print("\(paddedName)  \u{001B}[31mERROR: \(error.localizedDescription)\u{001B}[0m")
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        print("\u{001B}[90m---------------------------------------------------------------\u{001B}[0m")
        print("\n\u{001B}[90mNote: 'Front?' = Did app become frontmost after URL open\u{001B}[0m")
    }

    func togglePostLaunchBringForward() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "toggle flag on")
        guard let inst = instance else { return }

        let currentValue = launcher.getDisablePostLaunchBringForward(for: inst)
        print("\n\u{001B}[1mLSDisableAllPostLaunchBringForwardRequests\u{001B}[0m")
        print("  Current value: \(currentValue.map { $0 ? "true (disabled)" : "false (enabled)" } ?? "not set")")

        print("\n\u{001B}[1mSet to:\u{001B}[0m")
        print("\u{001B}[1;36m[1]\u{001B}[0m true (disable bring-forward)")
        print("\u{001B}[1;36m[2]\u{001B}[0m false (enable bring-forward)")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let newValue: Bool
        switch choice {
        case "1": newValue = true
        case "2": newValue = false
        default:
            print("\u{001B}[31mInvalid choice\u{001B}[0m")
            return
        }

        let status = launcher.setDisablePostLaunchBringForward(for: inst, disabled: newValue)

        if status == noErr {
            print("\u{001B}[32m✓ Set LSDisableAllPostLaunchBringForwardRequests = \(newValue)\u{001B}[0m")
        } else {
            print("\u{001B}[31m✗ Failed to set flag: OSStatus \(status)\u{001B}[0m")
        }
    }

    func showSessionFlags() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances

        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "show flags for")
        guard let inst = instance else { return }

        print("\n\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[1;35m                    SESSION FLAGS STATUS                        \u{001B}[0m")
        print("\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[90mApp: \(app.name) (PID: \(inst.processIdentifier))\u{001B}[0m\n")

        guard let asn = launcher.getASN(for: inst) else {
            print("\u{001B}[31mFailed to get ASN\u{001B}[0m")
            return
        }

        // Query various flags
        let flagsToQuery: [(String, String)] = [
            ("LSApplicationTypeKey", "kLSApplicationTypeKey"),
            ("LSApplicationTypeToRestoreKey", "kLSApplicationTypeToRestoreKey"),
            (LSMetaInfoKey.disableAllPostLaunchBringForwardRequests, "DisablePostLaunchBringForward"),
        ]

        print("\u{001B}[1mFlag                                    Value\u{001B}[0m")
        print("\u{001B}[90m---------------------------------------------------------------\u{001B}[0m")

        for (key, displayName) in flagsToQuery {
            let value = launcher.getApplicationInfo(asn: asn, key: key as CFString)
            let valueStr: String
            if let v = value {
                if CFGetTypeID(v) == CFBooleanGetTypeID() {
                    valueStr = CFBooleanGetValue(v as! CFBoolean) ? "true" : "false"
                } else if let str = v as? String {
                    valueStr = str
                } else {
                    valueStr = String(describing: v)
                }
            } else {
                valueStr = "(not set)"
            }
            let paddedName = displayName.padding(toLength: 38, withPad: " ", startingAt: 0)
            print("\(paddedName)  \(valueStr)")
        }

        print("\u{001B}[90m---------------------------------------------------------------\u{001B}[0m")

        // Also show current mode via our API
        if let mode = inst.applicationMode {
            print("\nCurrent Application Mode: \u{001B}[1;33m\(mode.rawValue)\u{001B}[0m")
        }

        let asnValue = launcher.asnToUInt64(asn)
        print("ASN: 0x\(String(asnValue, radix: 16))")
    }

    func getDefaultURL(for app: AppInfo) -> String {
        if app.bundleIdentifier.contains("Messages") || app.bundleIdentifier.contains("messages") {
            return "imessage://test"
        } else if app.bundleIdentifier.contains("Safari") || app.bundleIdentifier.contains("safari") {
            return "https://apple.com"
        } else if app.bundleIdentifier.contains("Mail") || app.bundleIdentifier.contains("mail") {
            return "mailto:test@example.com"
        } else if app.bundleIdentifier.contains("Slack") || app.bundleIdentifier.contains("slack") {
            return "slack://open"
        } else if app.bundleIdentifier.contains("Discord") || app.bundleIdentifier.contains("discord") {
            return "discord://open"
        } else {
            return "https://apple.com"
        }
    }

    // MARK: - SkyLight (Nuclear) Options

    func blockFromFrontSkyLight() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "block from front")
        guard let inst = instance else { return }

        print("\n\u{001B}[33mBlocking \(app.name) from becoming frontmost via SkyLight...\u{001B}[0m")

        let skylight = SkyLightBridge.shared
        print("  SkyLight available: \(skylight.isAvailable)")

        if let psn = skylight.extractPSN(for: inst) {
            print("  PSN: high=\(psn.high), low=\(psn.low)")
        }

        let success = skylight.blockFromFront(inst)
        if success {
            print("\u{001B}[32m✓ Blocked from front successfully\u{001B}[0m")
        } else {
            print("\u{001B}[31m✗ Failed to block from front\u{001B}[0m")
        }
    }

    func allowToFrontSkyLight() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "allow to front")
        guard let inst = instance else { return }

        print("\n\u{001B}[33mAllowing \(app.name) to become frontmost via SkyLight...\u{001B}[0m")

        let success = SkyLightBridge.shared.allowToFront(inst)
        if success {
            print("\u{001B}[32m✓ Allowed to front successfully\u{001B}[0m")
        } else {
            print("\u{001B}[31m✗ Failed to allow to front\u{001B}[0m")
        }
    }

    func removeFromPermittedFrontASNs() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "remove from permitted")
        guard let inst = instance else { return }

        print("\n\u{001B}[33mRemoving \(app.name) from permitted front ASNs...\u{001B}[0m")

        let status = launcher.removeFromPermittedFrontASNs(inst)
        if status == noErr {
            print("\u{001B}[32m✓ Removed from permitted front ASNs (status: \(status))\u{001B}[0m")
        } else {
            print("\u{001B}[31m✗ Failed to remove (status: \(status))\u{001B}[0m")
        }
    }

    func runSkyLightTest() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "test SkyLight on")
        guard let inst = instance else { return }

        print("\n\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[1;35m              SKYLIGHT FOREGROUND BLOCK TEST                   \u{001B}[0m")
        print("\u{001B}[1;35m===============================================================\u{001B}[0m")

        print("\n\u{001B}[1mEnter test URL (or press Enter for default):\u{001B}[0m ", terminator: "")
        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let urlString = urlInput.isEmpty ? getDefaultURL(for: app) : urlInput
        guard let url = URL(string: urlString) else {
            print("\u{001B}[31mInvalid URL\u{001B}[0m")
            return
        }

        print("\u{001B}[90mApp: \(app.name) (PID: \(inst.processIdentifier))\u{001B}[0m")
        print("\u{001B}[90mURL: \(url)\u{001B}[0m")

        let skylight = SkyLightBridge.shared
        print("\nSkyLight available: \(skylight.isAvailable)")

        if let psn = skylight.extractPSN(for: inst) {
            print("PSN: high=\(psn.high), low=\(psn.low)")
        }

        // Step 1: Lock to UIElement
        print("\n\u{001B}[1mStep 1: Lock to UIElement\u{001B}[0m")
        do {
            try launcher.lockToUIElement(inst)
            print("  \u{001B}[32m✓ Locked to UIElement\u{001B}[0m")
        } catch {
            print("  \u{001B}[31m✗ Failed: \(error)\u{001B}[0m")
        }
        Thread.sleep(forTimeInterval: 0.3)
        print("  Mode: \(inst.applicationMode?.rawValue ?? "?")")

        // Step 2: Block from front via SkyLight
        print("\n\u{001B}[1mStep 2: Block from front (SkyLight)\u{001B}[0m")
        let blocked = skylight.blockFromFront(inst)
        print("  \(blocked ? "\u{001B}[32m✓" : "\u{001B}[31m✗") blockFromFront: \(blocked)\u{001B}[0m")

        // Step 3: Also try the ASN approach
        print("\n\u{001B}[1mStep 3: Remove from permitted front ASNs\u{001B}[0m")
        let asnStatus = launcher.removeFromPermittedFrontASNs(inst)
        print("  Status: \(asnStatus)")

        // Step 4: Set session flag
        print("\n\u{001B}[1mStep 4: Set LSDisableAllPostLaunchBringForwardRequests\u{001B}[0m")
        let flagStatus = launcher.setDisablePostLaunchBringForward(for: inst, disabled: true)
        print("  Status: \(flagStatus)")

        // Capture state before URL
        let wasFrontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier == inst.processIdentifier
        let modeBefore = inst.applicationMode?.rawValue ?? "?"

        print("\n\u{001B}[1mStep 5: Open URL\u{001B}[0m")
        print("  Before: mode=\(modeBefore), isFront=\(wasFrontBefore)")

        // Open the URL with all suppression
        var options: [String: Any] = [
            LSFrontBoardOptionKey.activate: false,
            LSFrontBoardOptionKey.launchIsUserAction: false,
            LSFrontBoardOptionKey.foregroundLaunch: false,
            LSLaunchModifierKey.doNotBringFrontmost: true,
            LSLaunchModifierKey.doNotBringAnyWindowsForward: true,
        ]

        if let asn = launcher.getASN(for: inst) {
            launcher.openURLsWithOptions([url], targetASN: asn, options: options)
        }

        // Wait and check
        Thread.sleep(forTimeInterval: 1.0)

        let isFrontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier == inst.processIdentifier
        let modeAfter = inst.applicationMode?.rawValue ?? "?"

        print("  After:  mode=\(modeAfter), isFront=\(isFrontAfter)")

        print("\n\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")
        if !isFrontAfter && modeAfter != "Foreground" {
            print("\u{001B}[32m✓ SUCCESS: App stayed suppressed!\u{001B}[0m")
        } else if isFrontAfter {
            print("\u{001B}[31m✗ FAILED: App became frontmost\u{001B}[0m")
        } else if modeAfter == "Foreground" {
            print("\u{001B}[31m✗ FAILED: App mode changed to Foreground\u{001B}[0m")
        }
        print("\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")

        // Cleanup - allow back to front
        print("\n\u{001B}[90mCleaning up - restoring front permission...\u{001B}[0m")
        skylight.allowToFront(inst)
        launcher.setDisablePostLaunchBringForward(for: inst, disabled: false)
    }

    // MARK: - Watchdog Methods

    func openURLWithWatchdog() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "open URL with watchdog")
        guard let inst = instance else { return }

        print("\n\u{001B}[1mEnter URL (or press Enter for default):\u{001B}[0m ", terminator: "")
        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces) else { return }

        let urlString = urlInput.isEmpty ? getDefaultURL(for: app) : urlInput
        guard let url = URL(string: urlString) else {
            print("\u{001B}[31mInvalid URL\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[1;35m              WATCHDOG URL OPEN TEST                           \u{001B}[0m")
        print("\u{001B}[1;35m===============================================================\u{001B}[0m")
        print("\u{001B}[90mApp: \(app.name) (PID: \(inst.processIdentifier))\u{001B}[0m")
        print("\u{001B}[90mURL: \(url)\u{001B}[0m")

        print("\n\u{001B}[1mWatchdog interval (ms, default 50):\u{001B}[0m ", terminator: "")
        let intervalInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let intervalMs = Double(intervalInput) ?? 50
        let interval = intervalMs / 1000.0

        print("\n\u{001B}[33mStarting watchdog with \(intervalMs)ms interval...\u{001B}[0m")

        do {
            // Open with permanent watchdog
            try launcher.openURLsWithPermanentWatchdog([url], in: inst, watchInterval: interval)

            print("\u{001B}[32m✓ URL dispatched with watchdog active\u{001B}[0m")

            // Monitor for a few seconds
            print("\n\u{001B}[33mMonitoring for 5 seconds...\u{001B}[0m")

            for i in 1...10 {
                Thread.sleep(forTimeInterval: 0.5)
                let mode = inst.applicationMode?.rawValue ?? "?"
                let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == inst.processIdentifier
                print("  [\(i * 500)ms] mode=\(mode), isFront=\(isFront)")
            }

            let finalMode = inst.applicationMode?.rawValue ?? "?"
            let finalIsFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == inst.processIdentifier

            print("\n\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")
            if finalMode == "UIElement" && !finalIsFront {
                print("\u{001B}[32m✓ SUCCESS: App stayed as UIElement!\u{001B}[0m")
            } else {
                print("\u{001B}[31m✗ FAILED: mode=\(finalMode), isFront=\(finalIsFront)\u{001B}[0m")
            }
            print("\u{001B}[1;35m---------------------------------------------------------------\u{001B}[0m")

            // Stop watchdog
            print("\n\u{001B}[90mStopping watchdog...\u{001B}[0m")
            launcher.stopWatchdog(for: inst)

        } catch {
            print("\u{001B}[31m✗ Error: \(error)\u{001B}[0m")
        }
    }

    func toggleWatchdog() {
        guard let app = selectedApp else {
            print("\u{001B}[31mNo app selected. Press 1 to select an app first.\u{001B}[0m")
            return
        }

        let instances = app.runningInstances
        if instances.isEmpty {
            print("\n\u{001B}[33mNo running instances of \(app.name). Launch it first.\u{001B}[0m")
            return
        }

        let instance = instances.count == 1 ? instances[0] : selectInstance(from: instances, action: "toggle watchdog")
        guard let inst = instance else { return }

        let isWatching = ModeWatchdog.shared.isWatching(inst)

        if isWatching {
            print("\n\u{001B}[33mStopping watchdog for \(app.name)...\u{001B}[0m")
            ModeWatchdog.shared.stopWatching(inst)
            print("\u{001B}[32m✓ Watchdog stopped\u{001B}[0m")
        } else {
            print("\n\u{001B}[1mWatchdog interval (ms, default 50):\u{001B}[0m ", terminator: "")
            let intervalInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let intervalMs = Double(intervalInput) ?? 50
            let interval = intervalMs / 1000.0

            print("\n\u{001B}[33mStarting watchdog for \(app.name)...\u{001B}[0m")

            do {
                try launcher.lockToUIElementWithWatchdog(inst, watchInterval: interval)
                print("\u{001B}[32m✓ Watchdog started - app locked to UIElement\u{001B}[0m")
                print("\u{001B}[90mThe watchdog will continuously reset the mode if the app tries to change it.\u{001B}[0m")
                print("\u{001B}[90mRun option 24 again to stop the watchdog.\u{001B}[0m")
            } catch {
                print("\u{001B}[31m✗ Error: \(error)\u{001B}[0m")
            }
        }
    }
}

// MARK: - Main Entry Point

let cli = InteractiveCLI()
cli.run()
