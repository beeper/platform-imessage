// swiftlint:disable no_magic_numbers
import AppKit
import Darwin
import IMessageCore
import Testing
@testable import IMessage

@Test
func dockSuppressionUsesMatchingRestorationTypes() throws {
    var restoration: String?
    var current = "Foreground"
    var settlements = 0
    try MessagesDockSuppression.apply(write: { key, value in
        if key == "LSApplicationTypeToRestore" {
            restoration = value
        } else {
            // Model the server rule: an unmatched foreign write is ignored.
            if value == restoration { current = value }
        }
    }, read: {
        current
    }, settle: {
        settlements += 1
        if settlements == 1 {
            #expect(current == "UIElement")
        }
    })
    #expect(current == "invalid")
    #expect(settlements == 2)
}

@Test
func dockSuppressionRejectsSilentNoOpBeforeContinuing() {
    var writes = 0
    var settlements = 0
    #expect(throws: (any Error).self) {
        try MessagesDockSuppression.apply(write: { _, _ in writes += 1 }, read: { "Foreground" }, settle: { settlements += 1 })
    }
    #expect(writes == 2)
    #expect(settlements == 0)
}

@Test
func dockSuppressionPropagatesWriteFailure() {
    var writes = 0
    #expect(throws: (any Error).self) {
        try MessagesDockSuppression.apply(write: { _, _ in
            writes += 1
            throw ErrorMessage("LaunchServices rejected the write")
        }, read: {
            "Foreground"
        }, settle: {
            Issue.record("Must not settle after a failed write")
        })
    }
    #expect(writes == 1)
}

@Test
func dockRestorationUsesMatchingForegroundPair() throws {
    var current = "invalid"
    var writes: [String] = []
    var settlements = 0
    try MessagesDockSuppression.apply(
        target: .foreground,
        write: { key, value in
            writes.append("\(key)=\(value)")
            if key == "ApplicationType" { current = value }
        },
        read: {
            current
        },
        settle: {
            settlements += 1
        }
    )
    #expect(writes == ["LSApplicationTypeToRestore=Foreground", "ApplicationType=Foreground"])
    #expect(current == "Foreground")
    #expect(settlements == 1)
}

@Test
func dockRestorationRejectsSilentNoOp() {
    #expect(throws: (any Error).self) {
        try MessagesDockSuppression.apply(target: .foreground, write: { _, _ in }, read: { "invalid" }, settle: {
            Issue.record("Must not settle after a rejected restoration")
        })
    }
}

@Test
func dockSuppressionRestoresForegroundAfterPartialFailure() {
    var current = "Foreground"
    var restored = false
    #expect(throws: (any Error).self) {
        try MessagesDockSuppression.apply(write: { key, value in
            guard key == "ApplicationType" else { return }
            if value == "invalid" { throw ErrorMessage("Rejected final type") }
            current = value
            if value == "Foreground" { restored = true }
        }, read: {
            current
        }, settle: {})
    }
    #expect(restored)
    #expect(current == "Foreground")
}

@Test(arguments: [MessagesDockSuppression.Presentation.suppressed, .foreground])
func dockPresentationSkipsAlreadyAppliedType(target: MessagesDockSuppression.Presentation) throws {
    try MessagesDockSuppression.apply(
        target: target,
        write: { _, _ in
            Issue.record("Must not write an already-applied presentation")
        },
        read: {
            target.types.last
        },
        settle: {
            Issue.record("Must not delay an already-applied presentation")
        }
    )
}

// Explicit opt-in: this launches and closes a real secondary Messages process.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_SECONDARY_LAUNCH_SMOKE"] == "1"))
@MainActor
func secondaryMessagesLaunchSmoke() throws {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let compose = try #require(URL(string: "imessage:open?address=&body"))
    let launched = Protected<Result<NSRunningApplication, Error>?>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let result = Result { try MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: compose) }
        launched.withLock { $0 = result }
        done.signal()
    }
    // NSRunningApplication caches lifecycle state; its notifications need the
    // main run loop even though the synchronous launch runs on a worker.
    while done.wait(timeout: .now()) != .success { pumpLaunchSmokeRunLoop(for: 0.02) }
    let app = try #require(launched.read()).get()
    defer { if !app.isTerminated { app.terminate() } }
    #expect(!existing.contains { $0.processIdentifier == app.processIdentifier })

    for _ in 0..<3 {
        try MessagesInstanceTarget.sendDeepLink(compose, to: app)
        pumpLaunchSmokeRunLoop(for: 0.5)
        #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
        #expect(!app.isActive)
        let windows = try #require(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        #expect(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier })
    }
    // Exercise the shared coordinator hooks without moving or resizing a window.
    let coordinator = EclipsingWindowCoordinator()
    coordinator.app = app
    try coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    try coordinator.suppressDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "invalid")
    try coordinator.restoreDockPresence()
    #expect(try MessagesDockSuppression.applicationType(for: app.processIdentifier) == "Foreground")
    #expect(existing.allSatisfy { !$0.isTerminated })
    #expect(app.terminate())
    let deadline = Date().addingTimeInterval(5)
    while kill(app.processIdentifier, 0) == 0 && Date() < deadline {
        pumpLaunchSmokeRunLoop(for: 0.05)
    }
    #expect(kill(app.processIdentifier, 0) == -1 && errno == ESRCH)
}

@MainActor
private func pumpLaunchSmokeRunLoop(for interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

// swiftlint:enable no_magic_numbers
