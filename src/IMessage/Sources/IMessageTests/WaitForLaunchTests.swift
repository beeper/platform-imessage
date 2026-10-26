import AppKit
import Foundation
@testable import IMessage
import IMessageCore
import Testing

private let messagesBundleIdentifier = "com.apple.MobileSMS"

private struct LaunchTiming {
    let appName: String
    let processIdentifier: pid_t
    let elapsed: TimeInterval
}

@MainActor
private func terminateLaunchedApplication(_ app: NSRunningApplication) async {
    guard !app.isTerminated else { return }

    let bundleIdentifier = app.bundleIdentifier ?? "application"
    let processIdentifier = app.processIdentifier
    print("cleaning up launched \(bundleIdentifier) instance \(processIdentifier)")
    app.terminate()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !app.isTerminated {
        try? await Task.sleep(forTimeInterval: 0.05)
    }

    guard !app.isTerminated else { return }

    print("force terminating launched \(bundleIdentifier) instance \(processIdentifier)")
    app.forceTerminate()

    let forceTerminateDeadline = Date().addingTimeInterval(2)
    while Date() < forceTerminateDeadline, !app.isTerminated {
        try? await Task.sleep(forTimeInterval: 0.05)
    }

    if !app.isTerminated {
        print("timed out waiting to clean up \(bundleIdentifier) instance \(processIdentifier)")
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

    let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
    let app = try await Task.withTimeout(20, onLateSuccess: { app in
        if !existingPIDs.contains(app.processIdentifier) { app.terminate() }
    }) {
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
    try #require(!existingPIDs.contains(app.processIdentifier), "Refusing to clean up a pre-existing application")
    return app
}

@MainActor
private func withLaunchedApplication<Value>(_ action: (NSRunningApplication) async throws -> Value) async throws -> Value {
    let app = try await launchApplication(bundleIdentifier: messagesBundleIdentifier)
    let result = await Result(catching: { try await action(app) })
    await terminateLaunchedApplication(app)
    return try result.get()
}

@MainActor
private func waitForLaunchTiming(
    timeout: TimeInterval = 20
) async throws -> LaunchTiming {
    try await withLaunchedApplication { app in

        let startedAt = Date()
        try await app.waitForLaunch(timeout: timeout)
        let elapsed = Date().timeIntervalSince(startedAt)
        let appName = app.localizedName ?? messagesBundleIdentifier

        print("waitForLaunch for \(appName) pid \(app.processIdentifier) took \(String(format: "%.3f", elapsed))s")

        #expect(app.isFinishedLaunching)
        return LaunchTiming(appName: appName, processIdentifier: app.processIdentifier, elapsed: elapsed)
    }
}

// These stress tests launch and terminate real Messages processes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_LAUNCH_SMOKE"] == "1"))
@MainActor
struct WaitForLaunchTests {
    @Test func waitForLaunchRejectsTerminatedApplication() async throws {
        try await withLaunchedApplication { app in
            await terminateLaunchedApplication(app)
            await #expect(throws: ErrorMessage.self) {
                try await app.waitForLaunch(timeout: 1)
            }
        }
    }

    @Test func waitForLaunchPrintsLaunchDurationForSlowerApp() async throws {
        let timing = try await waitForLaunchTiming(
            timeout: 30
        )

        print("slower app launch candidate: \(timing.appName) pid \(timing.processIdentifier) finished in \(String(format: "%.3f", timing.elapsed))s")
    }

    @Test func waitForLaunchSequentialLaunchStress() async throws {
        let launchCount = 8
        var timings: [LaunchTiming] = []

        for index in 1...launchCount {
            let timing = try await waitForLaunchTiming(
                timeout: 20
            )
            print("sequential waitForLaunch stress \(index)/\(launchCount): pid \(timing.processIdentifier), \(String(format: "%.3f", timing.elapsed))s")
            timings.append(timing)
        }

        #expect(timings.count == launchCount)
    }

    @Test func waitForLaunchConcurrentWaiterStress() async throws {
        try await withLaunchedApplication { app in

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
}
