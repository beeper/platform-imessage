// swiftlint:disable no_magic_numbers
import IMessageCore
import Testing
@testable import IMessage

@Test
func dockSuppressionUsesMatchingRestorationTypes() async throws {
    var restoration: String?
    var current = "Foreground"
    var settlements = 0
    try await MessagesDockSuppression.apply(write: { key, value in
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
func dockSuppressionRejectsSilentNoOpBeforeContinuing() async {
    var writes = 0
    var settlements = 0
    await #expect(throws: (any Error).self) {
        try await MessagesDockSuppression.apply(write: { _, _ in writes += 1 }, read: { "Foreground" }, settle: { settlements += 1 })
    }
    #expect(writes == 2)
    #expect(settlements == 0)
}

@Test
func dockSuppressionPropagatesWriteFailure() async {
    var writes = 0
    await #expect(throws: (any Error).self) {
        try await MessagesDockSuppression.apply(write: { _, _ in
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
func dockRestorationUsesMatchingForegroundPair() async throws {
    var current = "invalid"
    var writes: [String] = []
    var settlements = 0
    try await MessagesDockSuppression.apply(
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
    #expect(settlements == 0)
}

@Test
func dockRestorationRejectsSilentNoOp() async {
    await #expect(throws: (any Error).self) {
        try await MessagesDockSuppression.apply(target: .foreground, write: { _, _ in }, read: { "invalid" }, settle: {
            Issue.record("Must not settle after a rejected restoration")
        })
    }
}

@Test
func dockSuppressionRestoresForegroundAfterPartialFailure() async {
    var current = "Foreground"
    await #expect(throws: (any Error).self) {
        try await MessagesDockSuppression.apply(write: { key, value in
            guard key == "ApplicationType" else { return }
            if value == "invalid" { throw ErrorMessage("Rejected final type") }
            current = value
        }, read: {
            current
        }, settle: {})
    }
    #expect(current == "Foreground")
}

@Test
func dockSuppressionRestoresForegroundWhenCancelledWhileSettling() async throws {
    // Cancelled before it starts, so the first real Task.sleep throws immediately.
    let task = Task { () async -> (error: (any Error)?, type: String) in
        var restoration: String?
        var current = "Foreground"
        do {
            try await MessagesDockSuppression.apply(write: { key, value in
                if key == "LSApplicationTypeToRestore" {
                    restoration = value
                } else if value == restoration {
                    current = value
                }
            }, read: {
                current
            }, settle: {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            })
            return (nil, current)
        } catch {
            return (error, current)
        }
    }
    task.cancel()
    let outcome = await task.value
    #expect(outcome.error is CancellationError)
    #expect(outcome.type == "Foreground", "Cancellation must not strand Messages as a UIElement")
}

@Test(arguments: [
    (MessagesDockSuppression.Presentation.suppressed, "invalid"),
    (.foreground, "Foreground"),
])
func dockPresentationSkipsAlreadyAppliedType(target: MessagesDockSuppression.Presentation, currentType: String) async throws {
    try await MessagesDockSuppression.apply(
        target: target,
        write: { _, _ in
            Issue.record("Must not write an already-applied presentation")
        },
        read: {
            currentType
        },
        settle: {
            Issue.record("Must not delay an already-applied presentation")
        }
    )
}

// swiftlint:enable no_magic_numbers
