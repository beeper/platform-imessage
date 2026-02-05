import Foundation
import AppKit
import ApplicationServices
import LSLauncher

// MARK: - Type Change Log Entry

struct TypeChangeLogEntry: Codable {
    let timestamp: String
    let pid: Int32
    let bundleID: String
    let oldType: String
    let newType: String
    let suppressionLatencyMs: Double?
    let deepLinkURL: String?
}

struct TypeChangeLog: Codable {
    var startedAt: String
    var entries: [TypeChangeLogEntry]
}

// MARK: - Messages Deep Link Tester CLI

final class MessagesDeepLinkTester {
    let launcher = LSApplicationLauncher.shared
    let observer = LSTypeObserver()

    let messagesBundleID = "com.apple.MobileSMS"
    let logFilePath: String
    let logLock = NSLock()

    var log = TypeChangeLog(startedAt: "", entries: [])
    var deepLinkStartTime: Date?
    var lastOpenedURL: URL?

    // Track the public instance PID (first one launched - should never be suppressed)
    var publicInstancePID: pid_t?
    var autoSuppressPuppets = false
    var sendMethod: LSApplicationLauncher.DeepLinkSendMethod = .cAPI
    var responsivenessCheckEnabled = true

    let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    let isoFormatter = ISO8601DateFormatter()

    init() {
        logFilePath = FileManager.default.currentDirectoryPath + "/type_changes.json"
        log.startedAt = isoFormatter.string(from: Date())
    }

    var shouldQuit = false

    func run() {
        printHeader()
        startObserver()
        launchTwoTestInstances()

        // Run input on a background thread so main queue can process notifications
        let inputQueue = DispatchQueue(label: "input", qos: .userInteractive)
        inputQueue.async { [weak self] in
            self?.inputLoop()
        }

        // Keep main thread alive to process notifications
        RunLoop.main.run()
    }

    func launchTwoTestInstances() {
        // First, quit all existing Messages instances
        let existingInstances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
        if !existingInstances.isEmpty {
            print("\u{001B}[33mQuitting \(existingInstances.count) existing Messages instance(s)...\u{001B}[0m")
            for app in existingInstances {
                app.forceTerminate()
            }
            // Wait for them to die
            Thread.sleep(forTimeInterval: 1.0)
        }

        print("\u{001B}[33mLaunching two Messages instances...\u{001B}[0m")

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else {
            print("\u{001B}[31mCould not find Messages app URL.\u{001B}[0m")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.allowsRunningApplicationSubstitution = false
        config.activates = false  // Don't steal focus
        config.hides = false      // Keep visible

        var launchedApps: [NSRunningApplication] = []
        let group = DispatchGroup()

        for i in 1...2 {
            group.enter()
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                if let app = app {
                    print("\u{001B}[32mInstance \(i) launched: PID \(app.processIdentifier)\u{001B}[0m")
                    launchedApps.append(app)
                } else if let error = error {
                    print("\u{001B}[31mInstance \(i) failed: \(error.localizedDescription)\u{001B}[0m")
                }
                group.leave()
            }
            // Small delay between launches
            Thread.sleep(forTimeInterval: 0.5)
        }

        group.wait()

        // Track the public instance and suppress only the second instance (puppet)
        if launchedApps.count >= 1 {
            publicInstancePID = launchedApps[0].processIdentifier
            print("\u{001B}[32mPublic instance: PID \(publicInstancePID!) (visible in dock)\u{001B}[0m")
        }

        if launchedApps.count >= 2 {
            let puppetInstance = launchedApps[1]
            print("\u{001B}[33mSuppressing puppet instance (PID \(puppetInstance.processIdentifier)) to UIElement...\u{001B}[0m")
            _ = puppetInstance.setApplicationMode(.uiElement)
            print("\u{001B}[32mPuppet instance: PID \(puppetInstance.processIdentifier) (suppressed)\u{001B}[0m\n")
        } else {
            print("\u{001B}[31mFailed to launch both instances.\u{001B}[0m\n")
        }
    }

    func inputLoop() {
        while !shouldQuit {
            printMenu()

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
                continue
            }

            switch input {
            case "1": testDeepLink(index: 0)
            case "2": testDeepLink(index: 1)
            case "3": testDeepLink(index: 2)
            case "4": testDeepLink(index: 3)
            case "5": testDeepLink(index: 4)
            case "c": testCustomDeepLink()
            case "n": launchNewInstance()
            case "t": runStressTest()
            case "a": runAsyncStressTest()
            case "s": showStatus()
            case "l": showLog()
            case "k": cleanupZombies()
            case "x": toggleAutoSuppress()
            case "r": refreshInstances()
            case "p": pingInstances()
            case "m": toggleSendMethod()
            case "o": toggleResponsivenessCheck()
            case "g": testLSOpenURLsUsingASN()
            case "q", "quit", "exit":
                observer.stopObserving()
                saveLog()
                print("\n\u{001B}[33mLog saved to: \(logFilePath)\u{001B}[0m")
                print("\u{001B}[1;33mGoodbye!\u{001B}[0m\n")
                shouldQuit = true
                exit(0)
            default:
                print("\u{001B}[31mInvalid option.\u{001B}[0m")
            }
        }
    }

    func printHeader() {
        print("\n\u{001B}[1;36m+============================================================+\u{001B}[0m")
        print("\u{001B}[1;36m|           Messages Deep Link Tester                        |\u{001B}[0m")
        print("\u{001B}[1;36m+============================================================+\u{001B}[0m\n")
    }

    func printMenu() {
        let instanceCount = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).count

        print("\n\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1mMessages:\u{001B}[0m \(instanceCount) instance(s)  \u{001B}[1mLog:\u{001B}[0m \(log.entries.count) entries")
        let suppressColor = autoSuppressPuppets ? "\u{001B}[32m" : "\u{001B}[33m"
        let suppressText = autoSuppressPuppets ? "ON" : "OFF"
        let publicPIDStr = publicInstancePID.map { "PID \($0)" } ?? "none"
        let methodShort = sendMethod == .cAPI ? "C API" : "NSAppleEventDescriptor"
        let respCheckColor = responsivenessCheckEnabled ? "\u{001B}[32m" : "\u{001B}[33m"
        let respCheckText = responsivenessCheckEnabled ? "ON" : "OFF"
        print("\u{001B}[32mType Observer: ON\u{001B}[0m  |  Auto-Suppress: \(suppressColor)\(suppressText)\u{001B}[0m  |  Public: \(publicPIDStr)")
        print("\u{001B}[36mSend Method: \(methodShort)\u{001B}[0m  |  Resp.Check: \(respCheckColor)\(respCheckText)\u{001B}[0m")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1mKishan Deep Links:\u{001B}[0m")
        print("  \u{001B}[1;36m[1]\u{001B}[0m 'hello' (2025-12-13)")
        print("  \u{001B}[1;36m[2]\u{001B}[0m 'test' (2025-12-13)")
        print("  \u{001B}[1;36m[3]\u{001B}[0m Attachment (2026-01-27 17:01)")
        print("  \u{001B}[1;36m[4]\u{001B}[0m Attachment (2026-01-27 05:27)")
        print("  \u{001B}[1;36m[5]\u{001B}[0m Attachment (2026-01-27 05:27)")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("  \u{001B}[1;36m[c]\u{001B}[0m Custom URL  \u{001B}[1;36m[n]\u{001B}[0m New Instance")
        print("  \u{001B}[1;36m[t]\u{001B}[0m Stress Test (sync)  \u{001B}[1;36m[a]\u{001B}[0m Stress Test (async)")
        print("  \u{001B}[1;36m[s]\u{001B}[0m Status  \u{001B}[1;36m[l]\u{001B}[0m Log  \u{001B}[1;36m[k]\u{001B}[0m Cleanup Extras")
        print("  \u{001B}[1;36m[r]\u{001B}[0m Refresh  \u{001B}[1;36m[p]\u{001B}[0m Ping  \u{001B}[1;36m[x]\u{001B}[0m Suppress  \u{001B}[1;36m[m]\u{001B}[0m Method  \u{001B}[1;36m[o]\u{001B}[0m Resp.Check")
        print("  \u{001B}[1;36m[g]\u{001B}[0m \u{001B}[1;33mLS ASN Test\u{001B}[0m (LaunchServices _LSOpenURLsUsingASN)")
        print("  \u{001B}[1;36m[q]\u{001B}[0m Quit")
        print("\u{001B}[1;35m-------------------------------------------------------------\u{001B}[0m")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")
    }

    // MARK: - Observer Setup

    func startObserver() {
        print("\u{001B}[33mStarting type observer (auto-suppress OFF)...\u{001B}[0m")

        // Start observing with our handler - NO auto-suppress so dock icons stay visible
        observer.startObserving { [weak self] bundleID, pid, oldType, newType in
            self?.handleTypeChange(bundleID: bundleID, pid: pid, oldType: oldType, newType: newType)
        }

        print("\u{001B}[32mReady. Type changes will be logged to: \(logFilePath)\u{001B}[0m")
    }

    func toggleAutoSuppress() {
        autoSuppressPuppets = !autoSuppressPuppets

        if !autoSuppressPuppets {
            print("\n\u{001B}[33mAuto-suppress OFF\u{001B}[0m - Puppet instances will stay visible in dock")
        } else {
            print("\n\u{001B}[32mAuto-suppress ON\u{001B}[0m - Puppet instances will be suppressed to UIElement")
            print("  Public PID: \(publicInstancePID.map { String($0) } ?? "not set") (protected)")

            // Immediately suppress any foreground instances EXCEPT the public one
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
            for app in instances {
                // Skip the public instance
                if app.processIdentifier == publicInstancePID {
                    print("  PID \(app.processIdentifier) (public) - keeping visible")
                    continue
                }
                if app.applicationMode == .foreground {
                    _ = app.setApplicationMode(.uiElement)
                    print("  PID \(app.processIdentifier) (puppet) - suppressed")
                }
            }
        }
    }

    func toggleSendMethod() {
        switch sendMethod {
        case .cAPI:
            sendMethod = .nsAppleEventDescriptor
            print("\n\u{001B}[36mSend method: NSAppleEventDescriptor\u{001B}[0m")
            print("  Uses higher-level Cocoa API")
            print("  Options: .neverInteract (default)")
        case .nsAppleEventDescriptor:
            sendMethod = .cAPI
            print("\n\u{001B}[36mSend method: C API (AESendMessage)\u{001B}[0m")
            print("  Uses lower-level Carbon API")
            print("  Mode: kAENoReply")
        }
    }

    func toggleResponsivenessCheck() {
        responsivenessCheckEnabled = !responsivenessCheckEnabled
        if responsivenessCheckEnabled {
            print("\n\u{001B}[32mResponsiveness check: ON\u{001B}[0m")
            print("  Instances will be pinged before stress test selection")
        } else {
            print("\n\u{001B}[33mResponsiveness check: OFF\u{001B}[0m")
            print("  Skipping ping check before stress test")
        }
    }

    func refreshInstances() {
        print("\n\u{001B}[1;33m=== REFRESH INSTANCES ===\u{001B}[0m")

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[31mNo Messages instances running.\u{001B}[0m")
            return
        }

        print("\u{001B}[1mCurrent instances (\(instances.count)):\u{001B}[0m")
        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let launching = app.isFinishedLaunching ? "ready" : "launching"
            let role = idx == 0 ? " (public)" : " (puppet)"
            print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(mode) - \(launching)\(role)")
        }

        print("\n\u{001B}[90mUse [p] to ping and check responsiveness.\u{001B}[0m")
    }

    func pingInstances() {
        print("\n\u{001B}[1;33m=== PING INSTANCES (AppleEvent responsiveness) ===\u{001B}[0m")

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[31mNo Messages instances running.\u{001B}[0m")
            return
        }

        print("Sending null AppleEvent to each instance (2s timeout)...\n")

        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let role = idx == 0 ? "public" : "puppet"
            print("  PID \(app.processIdentifier) (\(mode), \(role)): ", terminator: "")
            fflush(stdout)

            let startTime = CFAbsoluteTimeGetCurrent()
            let responsive = app.isResponsive(timeout: 2.0)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            if responsive {
                print("\u{001B}[32mResponsive\u{001B}[0m (\(String(format: "%.0f", elapsed))ms)")
            } else {
                print("\u{001B}[1;31mUNRESPONSIVE\u{001B}[0m (timed out)")
            }
        }

        print("")
    }

    // MARK: - LaunchServices ASN Test

    func testLSOpenURLsUsingASN() {
        print("\n\u{001B}[1;33m=== LaunchServices _LSOpenURLsUsingASN Test ===\u{001B}[0m")
        print("\u{001B}[90mThis uses _LSOpenURLsUsingASNWithCompletionHandler to send URLs\u{001B}[0m")
        print("\u{001B}[90mvia LaunchServices to a specific running instance (by ASN).\u{001B}[0m\n")

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[31mNo Messages instances running. Launch Messages first.\u{001B}[0m")
            return
        }

        print("\u{001B}[1mSelect target instance:\u{001B}[0m")
        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let role = app.processIdentifier == publicInstancePID ? " (public)" : " (puppet)"
            print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(mode)\(role)")
        }
        print("  [0] Cancel")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let choice = Int(input), choice > 0, choice <= instances.count else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        let targetApp = instances[choice - 1]
        let targetPID = targetApp.processIdentifier

        // Get ASN for the target
        guard let targetASN = launcher.createASN(pid: targetPID) else {
            print("\u{001B}[31mFailed to create ASN for PID \(targetPID)\u{001B}[0m")
            return
        }

        let asnValue = launcher.asnToUInt64(targetASN)
        print("\n\u{001B}[32mTarget ASN created:\u{001B}[0m 0x\(String(asnValue, radix: 16))")
        print("  PID: \(targetPID)")
        print("  Mode: \(targetApp.applicationMode?.rawValue ?? "Unknown")")

        // Select URL to send
        print("\n\u{001B}[1mSelect URL to send:\u{001B}[0m")
        for (idx, testURL) in testURLs.enumerated() {
            print("  [\(idx + 1)] \(testURL.desc)")
        }
        print("  [c] Custom URL")
        print("  [0] Cancel")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let urlInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        let urlToSend: URL
        if urlInput == "c" {
            print("\u{001B}[1mEnter URL:\u{001B}[0m ", terminator: "")
            guard let customURL = readLine()?.trimmingCharacters(in: .whitespaces),
                  let url = URL(string: customURL) else {
                print("\u{001B}[31mInvalid URL.\u{001B}[0m")
                return
            }
            urlToSend = url
        } else if let urlIndex = Int(urlInput), urlIndex > 0, urlIndex <= testURLs.count {
            guard let url = URL(string: testURLs[urlIndex - 1].url) else {
                print("\u{001B}[31mInvalid URL.\u{001B}[0m")
                return
            }
            urlToSend = url
        } else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        // Record state before
        let modeBefore = targetApp.applicationMode?.rawValue ?? "Unknown"
        let instanceCountBefore = instances.count

        print("\n\u{001B}[1;36mSending via _LSOpenURLsUsingASNWithCompletionHandler...\u{001B}[0m")
        print("  URL: \(urlToSend.absoluteString)")
        print("  Target ASN: 0x\(String(asnValue, radix: 16)) (PID \(targetPID))")

        deepLinkStartTime = Date()
        lastOpenedURL = urlToSend

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use the LaunchServices ASN API
        launcher.openURLs([urlToSend], targetASN: targetASN, activate: false, preferRunningInstance: true)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        print("\n\u{001B}[32mCall completed in \(String(format: "%.2f", elapsed))ms\u{001B}[0m")

        // Wait a moment for any type changes
        Thread.sleep(forTimeInterval: 0.5)

        // Check state after
        let modeAfter = targetApp.applicationMode?.rawValue ?? "Unknown"
        let instanceCountAfter = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).count
        let pidStillExists = NSRunningApplication(processIdentifier: targetPID) != nil

        print("\n\u{001B}[1mResults:\u{001B}[0m")
        print("  Mode before: \(modeBefore)")
        print("  Mode after:  \(modeAfter)")
        if modeBefore != modeAfter {
            print("  \u{001B}[1;33m>>> MODE CHANGED! <<<\u{001B}[0m")
        }
        print("  Instance count: \(instanceCountBefore) -> \(instanceCountAfter)")
        if instanceCountAfter > instanceCountBefore {
            print("  \u{001B}[1;31m>>> NEW INSTANCE SPAWNED! <<<\u{001B}[0m")
        }
        print("  Target PID exists: \(pidStillExists ? "Yes" : "No")")

        print("\n\u{001B}[90mWatch for type change notifications above...\u{001B}[0m")
    }

    func handleTypeChange(bundleID: String?, pid: pid_t, oldType: ApplicationMode?, newType: ApplicationMode?) {
        // This is called on main queue from LSTypeObserver
        let timestamp = Date()
        let timeStr = timeFormatter.string(from: timestamp)

        // Calculate suppression latency if applicable
        var suppressionLatencyMs: Double?
        if let start = deepLinkStartTime, newType == .uiElement {
            suppressionLatencyMs = timestamp.timeIntervalSince(start) * 1000
        }

        // Create log entry
        let entry = TypeChangeLogEntry(
            timestamp: isoFormatter.string(from: timestamp),
            pid: pid,
            bundleID: bundleID ?? "Unknown",
            oldType: oldType?.rawValue ?? "nil",
            newType: newType?.rawValue ?? "nil",
            suppressionLatencyMs: suppressionLatencyMs,
            deepLinkURL: lastOpenedURL?.absoluteString
        )

        // Append to log
        logLock.lock()
        log.entries.append(entry)
        saveLogUnsafe()
        logLock.unlock()

        // Print notification
        let bundle = bundleID ?? "Unknown"
        let old = oldType?.rawValue ?? "nil"
        let new = newType?.rawValue ?? "nil"

        let newColor: String
        switch newType {
        case .foreground: newColor = "\u{001B}[1;31m"  // Red - dock visible!
        case .uiElement: newColor = "\u{001B}[1;32m"   // Green - suppressed
        case .backgroundOnly: newColor = "\u{001B}[1;33m"
        case .none: newColor = "\u{001B}[90m"
        }

        print("\n\u{001B}[1;35m[\(timeStr)] TYPE CHANGE:\u{001B}[0m \(bundle) (PID: \(pid))")
        print("  \u{001B}[90m\(old)\u{001B}[0m -> \(newColor)\(new)\u{001B}[0m")

        if let latency = suppressionLatencyMs {
            print("  \u{001B}[36mSuppression latency: \(String(format: "%.1f", latency))ms\u{001B}[0m")
        }

        if newType == .foreground {
            print("  \u{001B}[1;31m>>> DOCK ICON VISIBLE! <<<\u{001B}[0m")

            // Auto-suppress puppet instances (not the public one)
            if autoSuppressPuppets && bundleID == messagesBundleID && pid != publicInstancePID {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    _ = app.setApplicationMode(.uiElement)
                    print("  \u{001B}[32m>>> Auto-suppressed puppet PID \(pid) <<<\u{001B}[0m")
                }
            }
        }

        print("")
        fflush(stdout)
    }

    // MARK: - Deep Link Testing

    let testURLs: [(url: String, desc: String)] = [
        ("imessage://open?message-guid=2D1F1B9E-9677-4BF2-BB29-30DF7DD02904", "'hello'"),
        ("imessage://open?message-guid=2AD5DA82-0DEF-4A12-B35D-09093AF6261A", "'test'"),
        ("imessage://open?message-guid=B19E7C73-77BA-424C-AB1B-DE2C9A856D42", "Attachment 1"),
        ("imessage://open?message-guid=1D6E621C-90FB-43F5-9329-A9B4B850D5A2", "Attachment 2"),
        ("imessage://open?message-guid=5283ECF2-B359-4AE7-B642-9630A27F2B04", "Attachment 3"),
    ]

    func testDeepLink(index: Int) {
        guard index < testURLs.count else { return }
        let testCase = testURLs[index]
        guard let url = URL(string: testCase.url) else { return }

        openDeepLink(url, description: testCase.desc)
    }

    func testCustomDeepLink() {
        print("\u{001B}[1mEnter deep link URL:\u{001B}[0m ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: input) else {
            print("\u{001B}[31mInvalid URL\u{001B}[0m")
            return
        }
        openDeepLink(url, description: "custom")
    }

    func openDeepLink(_ url: URL, description: String) {
        print("\n\u{001B}[33mOpening: \(description)\u{001B}[0m")
        print("  \u{001B}[90m\(url.absoluteString)\u{001B}[0m")

        // Record start time for latency measurement
        deepLinkStartTime = Date()
        lastOpenedURL = url

        // Open the deep link
        NSWorkspace.shared.open(url)

        print("\u{001B}[32mOpened. Watching for type changes...\u{001B}[0m")
    }

    // MARK: - Apple Event Deep Link Sending

    /// Creates an Apple Event descriptor for opening a URL in a target application
    func createAppleEventDescriptor(url: URL, targetApp: NSRunningApplication) -> NSAppleEventDescriptor {
        let eventDescriptor = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: targetApp.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        eventDescriptor.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )

        return eventDescriptor
    }

    /// Sends a deep link directly to a running application instance using Apple Events
    func sendDeepLink(_ url: URL, to app: NSRunningApplication, timeout: TimeInterval = 5) throws {
        let descriptor = createAppleEventDescriptor(url: url, targetApp: app)
        try descriptor.sendEvent(options: [.neverInteract, .waitForReply], timeout: timeout)
    }

    // MARK: - Stress Test

    func runStressTest() {
        print("\n\u{001B}[1;33m=== STRESS TEST ===\u{001B}[0m")

        // Get running Messages instances
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[31mNo Messages instances running. Launch Messages first.\u{001B}[0m")
            return
        }

        print("\u{001B}[1mSelect target instance:\u{001B}[0m")
        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(mode)")
        }
        print("  [0] Cancel")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let choice = Int(input), choice > 0, choice <= instances.count else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        let targetApp = instances[choice - 1]

        print("\n\u{001B}[1mNumber of iterations (default 20):\u{001B}[0m ", terminator: "")
        let iterInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let iterations = Int(iterInput) ?? 20

        print("\u{001B}[1mDelay between iterations in ms (default 20):\u{001B}[0m ", terminator: "")
        let delayInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let delayMs = Int(delayInput) ?? 20

        print("\n\u{001B}[1;36mStarting stress test:\u{001B}[0m")
        print("  Target PID: \(targetApp.processIdentifier)")
        print("  Iterations: \(iterations)")
        print("  Delay: \(delayMs)ms")
        print("  URLs: cycling through \(testURLs.count) test URLs")
        print("")

        // Record stress test start
        let stressTestStart = Date()
        var successCount = 0
        var failCount = 0
        var foregroundDetectedCount = 0

        // Track type changes during stress test
        let beforeEntryCount = log.entries.count

        for i in 0..<iterations {
            let urlIndex = i % testURLs.count
            guard let url = URL(string: testURLs[urlIndex].url) else { continue }

            let iterStart = Date()
            deepLinkStartTime = iterStart
            lastOpenedURL = url

            do {
                try sendDeepLink(url, to: targetApp)
                successCount += 1

                let elapsed = Date().timeIntervalSince(iterStart) * 1000
                print("\u{001B}[32m[\(i + 1)/\(iterations)]\u{001B}[0m Sent in \(String(format: "%.1f", elapsed))ms - \(testURLs[urlIndex].desc)")
            } catch {
                failCount += 1
                print("\u{001B}[31m[\(i + 1)/\(iterations)]\u{001B}[0m Failed: \(error.localizedDescription)")
            }

            // Check if app became foreground
            if targetApp.applicationMode == .foreground {
                foregroundDetectedCount += 1
                print("  \u{001B}[1;31m>>> FOREGROUND DETECTED! <<<\u{001B}[0m")

                // Immediate suppression if auto-suppress is enabled and this is a puppet
                if autoSuppressPuppets && targetApp.processIdentifier != publicInstancePID {
                    _ = targetApp.setApplicationMode(.uiElement)
                    print("  \u{001B}[32m>>> Suppressed <<<\u{001B}[0m")
                }
            }

            // Delay before next iteration
            if i < iterations - 1 {
                Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
            }
        }

        // Wait a bit for final type change notifications to arrive
        Thread.sleep(forTimeInterval: 0.5)

        let totalTime = Date().timeIntervalSince(stressTestStart)
        let afterEntryCount = log.entries.count
        let typeChanges = afterEntryCount - beforeEntryCount

        // Count how many times we saw Foreground in the new type changes
        let foregroundTransitions = log.entries.suffix(typeChanges).filter { $0.newType == "Foreground" }.count
        let suppressions = log.entries.suffix(typeChanges).filter { $0.newType == "UIElement" }.count

        print("\n\u{001B}[1;33m=== STRESS TEST RESULTS ===\u{001B}[0m")
        print("  Total time: \(String(format: "%.2f", totalTime))s")
        print("  Successful sends: \(successCount)")
        print("  Failed sends: \(failCount)")
        print("  Type change events: \(typeChanges)")
        print("  Foreground transitions: \u{001B}[31m\(foregroundTransitions)\u{001B}[0m")
        print("  UIElement suppressions: \u{001B}[32m\(suppressions)\u{001B}[0m")
        print("  Foreground detected during send: \(foregroundDetectedCount)")

        if foregroundTransitions > 0 {
            print("\n\u{001B}[1;31m⚠️  Auto-suppression may be too slow!\u{001B}[0m")
        } else {
            print("\n\u{001B}[1;32m✓ Auto-suppression kept up with the load.\u{001B}[0m")
        }

        // Calculate average suppression latency
        let latencies = log.entries.suffix(typeChanges).compactMap { $0.suppressionLatencyMs }
        if !latencies.isEmpty {
            let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
            let maxLatency = latencies.max() ?? 0
            let minLatency = latencies.min() ?? 0
            print("\n\u{001B}[1mSuppression Latency:\u{001B}[0m")
            print("  Min: \(String(format: "%.1f", minLatency))ms")
            print("  Avg: \(String(format: "%.1f", avgLatency))ms")
            print("  Max: \(String(format: "%.1f", maxLatency))ms")
        }

        // Final suppression pass - ensure all puppets are suppressed
        if autoSuppressPuppets {
            print("\n\u{001B}[33mFinal suppression pass...\u{001B}[0m")
            let finalInstances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
            for app in finalInstances {
                if app.processIdentifier != publicInstancePID && app.applicationMode == .foreground {
                    _ = app.setApplicationMode(.uiElement)
                    print("  Suppressed PID \(app.processIdentifier)")
                }
            }
        }
    }

    // MARK: - Async Stress Test (with monitoring)

    func runAsyncStressTest() {
        print("\n\u{001B}[1;33m=== ASYNC STRESS TEST (with monitoring) ===\u{001B}[0m")

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[31mNo Messages instances running. Launch Messages first.\u{001B}[0m")
            return
        }

        print("\u{001B}[1mSelect target instance:\u{001B}[0m")
        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let launching = app.isFinishedLaunching ? "ready" : "launching"
            let role = idx == 0 ? " (public)" : " (puppet)"

            if responsivenessCheckEnabled {
                // Quick responsiveness check
                print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(mode) (\(launching))\(role) - ", terminator: "")
                fflush(stdout)
                let responsive = app.isResponsive(timeout: 1.0)
                if responsive {
                    print("\u{001B}[32mOK\u{001B}[0m")
                } else {
                    print("\u{001B}[1;31mUNRESPONSIVE\u{001B}[0m")
                }
            } else {
                print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(mode) (\(launching))\(role)")
            }
        }
        print("  [0] Cancel")
        print("\u{001B}[1mChoice:\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let choice = Int(input), choice > 0, choice <= instances.count else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        let targetApp = instances[choice - 1]

        print("\n\u{001B}[1mNumber of iterations (default 20):\u{001B}[0m ", terminator: "")
        let iterInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let iterations = Int(iterInput) ?? 20

        print("\u{001B}[1mDelay between iterations in ms (default 20):\u{001B}[0m ", terminator: "")
        let delayInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let delayMs = Int(delayInput) ?? 20

        let methodName = sendMethod == .cAPI ? "C API" : "NSAppleEventDescriptor"
        print("\n\u{001B}[1;36mStarting ASYNC stress test:\u{001B}[0m")
        print("  Target PID: \(targetApp.processIdentifier)")
        print("  Iterations: \(iterations)")
        print("  Delay: \(delayMs)ms")
        print("  Send method: \(methodName)")
        print("  Mode: Background thread with continuation")
        print("")

        let stressTestStart = Date()
        var results: [LSApplicationLauncher.DeepLinkSendResult] = []
        let currentMethod = sendMethod  // Capture for async block

        // Use a semaphore to coordinate async work from sync context
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            for i in 0..<iterations {
                let urlIndex = i % testURLs.count
                guard let url = URL(string: testURLs[urlIndex].url) else { continue }

                deepLinkStartTime = Date()
                lastOpenedURL = url

                // Use the async send method with selected method
                let result = await launcher.sendURLAsync(
                    url.absoluteString,
                    to: targetApp,
                    bundleIdentifier: messagesBundleID,
                    method: currentMethod
                )
                results.append(result)

                // Print detailed result
                let statusStr: String
                if result.success {
                    statusStr = "\u{001B}[32mOK\u{001B}[0m"
                } else if let err = result.error {
                    statusStr = "\u{001B}[31mERR: \(err)\u{001B}[0m"
                } else {
                    statusStr = "\u{001B}[31mERR \(result.status)\u{001B}[0m"
                }
                let launchStr = result.isFinishedLaunchingAfter ? "ready" : "\u{001B}[33mlaunching\u{001B}[0m"
                let spawnStr = result.newInstanceSpawned ? " \u{001B}[1;31mNEW INSTANCE!\u{001B}[0m" : ""

                print("[\(i + 1)/\(iterations)] \(statusStr) \(String(format: "%.1f", result.sendDurationMs))ms | \(launchStr) | instances: \(result.instanceCountBefore)→\(result.instanceCountAfter)\(spawnStr)")

                // Check foreground state
                if targetApp.applicationMode == .foreground {
                    print("  \u{001B}[1;31m>>> FOREGROUND DETECTED! <<<\u{001B}[0m")

                    // Immediate suppression if auto-suppress is enabled and this is a puppet
                    if autoSuppressPuppets && targetApp.processIdentifier != publicInstancePID {
                        _ = targetApp.setApplicationMode(.uiElement)
                        print("  \u{001B}[32m>>> Suppressed <<<\u{001B}[0m")
                    }
                }

                // Delay before next iteration
                if i < iterations - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }

            semaphore.signal()
        }

        // Wait for async work to complete
        semaphore.wait()

        // Wait for final notifications
        Thread.sleep(forTimeInterval: 0.5)

        let totalTime = Date().timeIntervalSince(stressTestStart)

        print("\n\u{001B}[1;33m=== ASYNC STRESS TEST RESULTS ===\u{001B}[0m")
        print("  Total time: \(String(format: "%.2f", totalTime))s")
        print("  Successful sends: \(results.filter { $0.success }.count)")
        print("  Failed sends: \(results.filter { !$0.success }.count)")
        print("  New instances spawned: \(results.filter { $0.newInstanceSpawned }.count)")

        // Analyze send duration
        let durations = results.map { $0.sendDurationMs }
        if !durations.isEmpty {
            let avgDuration = durations.reduce(0, +) / Double(durations.count)
            let maxDuration = durations.max() ?? 0
            let minDuration = durations.min() ?? 0
            print("\n\u{001B}[1mAppleEvent Send Duration:\u{001B}[0m")
            print("  Min: \(String(format: "%.1f", minDuration))ms")
            print("  Avg: \(String(format: "%.1f", avgDuration))ms")
            print("  Max: \(String(format: "%.1f", maxDuration))ms")
        }

        // Count how many times isFinishedLaunching changed
        let launchingChanges = results.filter { $0.isFinishedLaunchingBefore != $0.isFinishedLaunchingAfter }.count
        if launchingChanges > 0 {
            print("\n\u{001B}[1;33misFinishedLaunching changed \(launchingChanges) times during test\u{001B}[0m")
        }

        // Final instance count and responsiveness check
        let finalInstances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
        print("\n\u{001B}[1mFinal state:\u{001B}[0m \(finalInstances.count) instance(s)")

        if responsivenessCheckEnabled {
            print("\n\u{001B}[1mPost-test responsiveness check:\u{001B}[0m")
            for (idx, app) in finalInstances.enumerated() {
                let mode = app.applicationMode?.rawValue ?? "Unknown"
                let role = idx == 0 ? "public" : "puppet"
                let wasTarget = app.processIdentifier == targetApp.processIdentifier ? " \u{001B}[1;36m<- TARGET\u{001B}[0m" : ""
                print("  PID \(app.processIdentifier) (\(mode), \(role))\(wasTarget): ", terminator: "")
                fflush(stdout)

                let responsive = app.isResponsive(timeout: 2.0)
                if responsive {
                    print("\u{001B}[32mResponsive\u{001B}[0m")
                } else {
                    print("\u{001B}[1;31mUNRESPONSIVE\u{001B}[0m")
                }
            }
        }

        // Check if target PID still exists
        if NSRunningApplication(processIdentifier: targetApp.processIdentifier) == nil {
            print("\n\u{001B}[1;31mWARNING: Target PID \(targetApp.processIdentifier) no longer exists!\u{001B}[0m")
        }

        // Final suppression pass - ensure all puppets are suppressed
        if autoSuppressPuppets {
            print("\n\u{001B}[33mFinal suppression pass...\u{001B}[0m")
            for app in finalInstances {
                if app.processIdentifier != publicInstancePID && app.applicationMode == .foreground {
                    _ = app.setApplicationMode(.uiElement)
                    print("  Suppressed PID \(app.processIdentifier)")
                }
            }
        }
    }

    // MARK: - Cleanup (kill all except first/public instance)

    func cleanupZombies() {
        print("\n\u{001B}[1;33m=== CLEANUP EXTRA INSTANCES ===\u{001B}[0m")

        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        if instances.isEmpty {
            print("\u{001B}[33mNo Messages instances running.\u{001B}[0m")
            return
        }

        if instances.count == 1 {
            print("\u{001B}[32mOnly one instance running (the public app). Nothing to clean up.\u{001B}[0m")
            return
        }

        // First instance is the "public" one, rest are extras/puppets
        let publicInstance = instances[0]
        let extraInstances = Array(instances.dropFirst())

        print("\u{001B}[1mPublic instance (keeping):\u{001B}[0m")
        let publicMode = publicInstance.applicationMode?.rawValue ?? "Unknown"
        print("  PID \(publicInstance.processIdentifier) (\(publicMode))")

        print("\n\u{001B}[1mExtra instances (\(extraInstances.count)):\u{001B}[0m")
        for app in extraInstances {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            print("  PID \(app.processIdentifier) (\(mode)): ", terminator: "")
            fflush(stdout)

            if app.isResponsive(timeout: 2.0) {
                print("\u{001B}[32mResponsive\u{001B}[0m")
            } else {
                print("\u{001B}[1;31mZOMBIE\u{001B}[0m")
            }
        }

        print("\n\u{001B}[1mKill all \(extraInstances.count) extra instance(s)? (y/n):\u{001B}[0m ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              input == "y" || input == "yes" else {
            print("\u{001B}[33mCancelled.\u{001B}[0m")
            return
        }

        var killed = 0
        for app in extraInstances {
            print("  Killing PID \(app.processIdentifier)... ", terminator: "")
            if app.forceTerminate() {
                print("\u{001B}[32mOK\u{001B}[0m")
                killed += 1
            } else {
                print("\u{001B}[31mFailed\u{001B}[0m")
            }
        }

        print("\n\u{001B}[32mKilled \(killed)/\(extraInstances.count) extra instance(s).\u{001B}[0m")

        // Show remaining instances
        Thread.sleep(forTimeInterval: 0.5)
        let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
        print("\u{001B}[1mRemaining instances:\u{001B}[0m \(remaining.count)")
    }

    // MARK: - Launch New Instance

    func launchNewInstance() {
        print("\n\u{001B}[1;33m=== LAUNCH NEW INSTANCE ===\u{001B}[0m")

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else {
            print("\u{001B}[31mCould not find Messages app URL.\u{001B}[0m")
            return
        }

        print("\u{001B}[1mLaunch as hidden/suppressed? (y/n, default y):\u{001B}[0m ", terminator: "")
        let hiddenInput = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "y"
        let shouldHide = hiddenInput != "n"

        print("\u{001B}[33mLaunching new Messages instance (hidden: \(shouldHide))...\u{001B}[0m")

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.allowsRunningApplicationSubstitution = false
        config.activates = !shouldHide
        config.hides = shouldHide

        let semaphore = DispatchSemaphore(value: 0)
        var launchedApp: NSRunningApplication?
        var launchError: Error?

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            launchedApp = app
            launchError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let error = launchError {
            print("\u{001B}[31mFailed to launch: \(error.localizedDescription)\u{001B}[0m")
            return
        }

        guard let app = launchedApp else {
            print("\u{001B}[31mNo application returned.\u{001B}[0m")
            return
        }

        print("\u{001B}[32mLaunched new instance:\u{001B}[0m")
        print("  PID: \(app.processIdentifier)")
        print("  Mode: \(app.applicationMode?.rawValue ?? "Unknown")")

        // If hidden, suppress it immediately
        if shouldHide {
            print("\u{001B}[33mSuppressing to UIElement...\u{001B}[0m")
            let result = launcher.setApplicationMode(for: app, to: .uiElement)
            if result == noErr {
                print("\u{001B}[32mSuppressed successfully.\u{001B}[0m")
                print("  Mode: \(app.applicationMode?.rawValue ?? "Unknown")")
            } else {
                print("\u{001B}[31mFailed to suppress (error: \(result)).\u{001B}[0m")
            }
        }

        // Add to auto-suppress
        observer.addAutoSuppress(bundleID: messagesBundleID)

        print("\n\u{001B}[90mInstance added to auto-suppress list.\u{001B}[0m")
    }

    // MARK: - Status & Log

    func showStatus() {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)

        print("\n\u{001B}[1mMessages Instances (\(instances.count)):\u{001B}[0m")

        if instances.isEmpty {
            print("  \u{001B}[90mNo instances running\u{001B}[0m")
            return
        }

        for (idx, app) in instances.enumerated() {
            let mode = app.applicationMode?.rawValue ?? "Unknown"
            let modeColor: String
            switch app.applicationMode {
            case .foreground: modeColor = "\u{001B}[31m"
            case .uiElement: modeColor = "\u{001B}[32m"
            case .backgroundOnly: modeColor = "\u{001B}[33m"
            case .none: modeColor = "\u{001B}[90m"
            }
            print("  [\(idx + 1)] PID: \(app.processIdentifier) - \(modeColor)\(mode)\u{001B}[0m")
        }
    }

    func showLog() {
        if log.entries.isEmpty {
            print("\n\u{001B}[33mNo type changes recorded yet.\u{001B}[0m")
            return
        }

        print("\n\u{001B}[1mType Change Log (last 10):\u{001B}[0m")
        print("\u{001B}[90m-------------------------------------------------------------\u{001B}[0m")

        for entry in log.entries.suffix(10) {
            // Parse timestamp for display
            if let date = isoFormatter.date(from: entry.timestamp) {
                let timeStr = timeFormatter.string(from: date)
                print("\u{001B}[90m[\(timeStr)]\u{001B}[0m PID \(entry.pid): \(entry.oldType) -> \u{001B}[1;33m\(entry.newType)\u{001B}[0m")
                if let latency = entry.suppressionLatencyMs {
                    print("  \u{001B}[36mLatency: \(String(format: "%.1f", latency))ms\u{001B}[0m")
                }
            }
        }

        print("\n\u{001B}[90mFull log: \(logFilePath)\u{001B}[0m")
    }

    func saveLog() {
        logLock.lock()
        saveLogUnsafe()
        logLock.unlock()
    }

    private func saveLogUnsafe() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(log)
            try data.write(to: URL(fileURLWithPath: logFilePath))
        } catch {
            // Silent fail in background thread
        }
    }
}

// MARK: - Main Entry Point

let tester = MessagesDeepLinkTester()
tester.run()
