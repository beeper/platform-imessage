import AppKit
import IMessageCore
@testable import IMessage
import Testing

@Test @MainActor func pasteboardRestorationCompletesBeforeNextSerializedOperation() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("original", forType: .string)
    let lane = MessagesControllerAutomationLane(idleDelay: 10)
    for value in ["first file", "second file"] {
        try await lane.run {
            await board.withRestoration {
                board.setString(value, forType: .string)
            }
        }
        #expect(board.string(forType: .string) == "original")
    }
}

@Test @MainActor func pasteboardRestorationCompletesOnCancellation() async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("original", forType: .string)
    let started = Protected(false)
    let task = Task {
        try await board.withRestoration {
            board.setString("temporary file", forType: .string)
            started.withLock { $0 = true }
            try await Task.sleep(forTimeInterval: 60)
        }
    }
    #expect(await eventually { started.read() })
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(board.string(forType: .string) == "original")
}
