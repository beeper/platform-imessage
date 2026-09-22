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

private func terminateLaunchedApplication(_ app: NSRunningApplication) {
    guard !app.isTerminated else { return }

    let bundleIdentifier = app.bundleIdentifier ?? "application"
    let processIdentifier = app.processIdentifier
    print("cleaning up launched \(bundleIdentifier) instance \(processIdentifier)")
    app.terminate()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !app.isTerminated {
        Thread.sleep(forTimeInterval: 0.05)
    }

    guard !app.isTerminated else { return }

    print("force terminating launched \(bundleIdentifier) instance \(processIdentifier)")
    app.forceTerminate()

    let forceTerminateDeadline = Date().addingTimeInterval(2)
    while Date() < forceTerminateDeadline, !app.isTerminated {
        Thread.sleep(forTimeInterval: 0.05)
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

    return try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
}

private func waitForLaunchTiming(
    bundleIdentifier: String,
    timeout: TimeInterval = 20
) async throws -> LaunchTiming {
    let app = try await launchApplication(bundleIdentifier: bundleIdentifier)
    defer { terminateLaunchedApplication(app) }

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
        let app = try await launchApplication(bundleIdentifier: messagesBundleIdentifier)
        defer { terminateLaunchedApplication(app) }

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
