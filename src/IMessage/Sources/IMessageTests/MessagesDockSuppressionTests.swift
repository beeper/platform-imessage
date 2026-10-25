// swiftlint:disable no_magic_numbers
import IMessageCore
import Testing
@testable import IMessage

@Test(arguments: [
    (false, false, false),
    (false, true, false),
    (true, false, false),
    (true, true, true),
])
func dockSuppressionGate(enabled: Bool, secondary: Bool, shouldSuppress: Bool) {
    #expect(Defaults.shouldSuppressMessagesDock(enabled: enabled, secondary: secondary) == shouldSuppress)
}

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
    #expect(settlements == 0)
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
    #expect(throws: (any Error).self) {
        try MessagesDockSuppression.apply(write: { key, value in
            guard key == "ApplicationType" else { return }
            if value == "invalid" { throw ErrorMessage("Rejected final type") }
            current = value
        }, read: {
            current
        }, settle: {})
    }
    #expect(current == "Foreground")
}

@Test(arguments: [
    (MessagesDockSuppression.Presentation.suppressed, "invalid"),
    (.foreground, "Foreground"),
])
func dockPresentationSkipsAlreadyAppliedType(target: MessagesDockSuppression.Presentation, currentType: String) throws {
    try MessagesDockSuppression.apply(
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
