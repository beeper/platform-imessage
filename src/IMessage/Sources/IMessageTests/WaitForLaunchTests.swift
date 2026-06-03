import AppKit
import Foundation
@testable import IMessage
import Testing

private let messagesBundleIdentifier = "com.apple.MobileSMS"

private struct LaunchTiming {
    let appName: String
    let processIdentifier: pid_t
    let elapsed: TimeInterval
}

private struct LaunchedApplicationCleanup {
    let bundleIdentifier: String
    let preservedPIDs: Set<pid_t>

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.preservedPIDs = Self.runningPIDs(bundleIdentifier: bundleIdentifier)
    }

    func terminateLaunchedApplications() {
        var apps = Self.newApplications(bundleIdentifier: bundleIdentifier, preserving: preservedPIDs)
        guard !apps.isEmpty else { return }

        print("cleaning up \(apps.count) launched \(bundleIdentifier) instance(s): \(apps.map(\.processIdentifier).sorted())")
        for app in apps where !app.isTerminated {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            apps = Self.newApplications(bundleIdentifier: bundleIdentifier, preserving: preservedPIDs)
            if apps.allSatisfy(\.isTerminated) || apps.isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let remaining = Self.newApplications(bundleIdentifier: bundleIdentifier, preserving: preservedPIDs)
            .filter { !$0.isTerminated }
        for app in remaining {
            print("force terminating launched \(bundleIdentifier) instance \(app.processIdentifier)")
            app.forceTerminate()
        }

        let forceTerminateDeadline = Date().addingTimeInterval(2)
        while Date() < forceTerminateDeadline {
            let apps = Self.newApplications(bundleIdentifier: bundleIdentifier, preserving: preservedPIDs)
                .filter { !$0.isTerminated }
            if apps.isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stillRunning = Self.newApplications(bundleIdentifier: bundleIdentifier, preserving: preservedPIDs)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
            .sorted()
        if !stillRunning.isEmpty {
            print("timed out waiting to clean up \(bundleIdentifier) instance(s): \(stillRunning)")
        }
    }

    private static func runningPIDs(bundleIdentifier: String) -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
    }

    private static func newApplications(
        bundleIdentifier: String,
        preserving preservedPIDs: Set<pid_t>
    ) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !preservedPIDs.contains($0.processIdentifier) }
    }
}

private func launchApplication(bundleIdentifier: String) async throws -> NSRunningApplication {
    let appURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier))

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.hides = true
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    configuration.launchIsUserAction = true
    configuration.preferRunningInstance = false
    configuration.launchWithoutRestoringState = true
    configuration.waitForApplicationToCheckIn = true

    return try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
}

private func waitForLaunchTiming(
    bundleIdentifier: String,
    timeout: TimeInterval = 20
) async throws -> LaunchTiming {
    let cleanup = LaunchedApplicationCleanup(bundleIdentifier: bundleIdentifier)
    defer { cleanup.terminateLaunchedApplications() }

    let app = try await launchApplication(bundleIdentifier: bundleIdentifier)
    let startedAt = Date()
    try await app.waitForLaunch(timeout: timeout)
    let elapsed = Date().timeIntervalSince(startedAt)
    let appName = app.localizedName ?? bundleIdentifier

    print("waitForLaunch for \(appName) pid \(app.processIdentifier) took \(String(format: "%.3f", elapsed))s")

    #expect(app.isFinishedLaunching)
    return LaunchTiming(appName: appName, processIdentifier: app.processIdentifier, elapsed: elapsed)
}

@Suite(.serialized)
struct WaitForLaunchTests {
    @Test func waitForLaunchPrintsLaunchDurationForSlowerApp() async throws {
        let timing = try await waitForLaunchTiming(
            bundleIdentifier: messagesBundleIdentifier,
            timeout: 30
        )

        print("slower app launch candidate: \(timing.appName) pid \(timing.processIdentifier) finished in \(String(format: "%.3f", timing.elapsed))s")
    }

    @Test func waitForLaunchSequentialLaunchStress() async throws {
        let launchCount = 8
        var timings: [LaunchTiming] = []

        for index in 1...launchCount {
            let timing = try await waitForLaunchTiming(
                bundleIdentifier: messagesBundleIdentifier,
                timeout: 20
            )
            print("sequential waitForLaunch stress \(index)/\(launchCount): pid \(timing.processIdentifier), \(String(format: "%.3f", timing.elapsed))s")
            timings.append(timing)
        }

        #expect(timings.count == launchCount)
    }

    @Test func waitForLaunchConcurrentWaiterStress() async throws {
        let cleanup = LaunchedApplicationCleanup(bundleIdentifier: messagesBundleIdentifier)
        defer { cleanup.terminateLaunchedApplications() }

        let app = try await launchApplication(bundleIdentifier: messagesBundleIdentifier)
        let waiterCount = 8

        let elapsedTimes = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for _ in 0..<waiterCount {
                group.addTask {
                    let startedAt = Date()
                    try await app.waitForLaunch(timeout: 20)
                    return Date().timeIntervalSince(startedAt)
                }
            }

            var elapsedTimes: [TimeInterval] = []
            for try await elapsed in group {
                elapsedTimes.append(elapsed)
            }
            return elapsedTimes
        }

        for (index, elapsed) in elapsedTimes.enumerated() {
            print("concurrent waitForLaunch waiter stress \(index + 1)/\(waiterCount): pid \(app.processIdentifier), \(String(format: "%.3f", elapsed))s")
        }

        #expect(elapsedTimes.count == waiterCount)
        #expect(app.isFinishedLaunching)
    }
}
