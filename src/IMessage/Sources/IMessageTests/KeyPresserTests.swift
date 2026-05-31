import Carbon.HIToolbox.Events
import Foundation
@testable import IMessage
@testable import IMessageCore
import Testing

private func runOffMainThread(_ operation: @escaping () -> Void) async {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "KeyPresserTests.background").async {
            operation()
            continuation.resume()
        }
    }
}

@Test func keyPressRunsOnCallingThreadByDefault() async throws {
    let result = Protected<Result<Void, Error>?>()
    let observedKeyPress = Protected<(key: CGKeyCode, flags: CGEventFlags?, isMainThread: Bool)?>()

    await runOffMainThread {
        let keyPresser = KeyPresser(pid: 0) { key, flags in
            observedKeyPress.withLock { $0 = (key, flags, Thread.isMainThread) }
        }

        result.withLock {
            $0 = Result { try keyPresser.return() }
        }
    }

    try #require(result.read()).get()
    let observed = try #require(observedKeyPress.read())
    #expect(observed.key == CGKeyCode(kVK_Return))
    #expect(observed.flags == nil)
    #expect(observed.isMainThread == false)
}

@Test func keyPressCanOptIntoMainThreadDispatch() async throws {
    let result = Protected<Result<Void, Error>?>()
    let observedIsMainThread = Protected<Bool?>()

    await runOffMainThread {
        let keyPresser = KeyPresser(pid: 0) { _, _ in
            observedIsMainThread.withLock { $0 = Thread.isMainThread }
        }

        result.withLock {
            $0 = Result { try keyPresser.return(onMainThread: true) }
        }
    }

    try #require(result.read()).get()
    let isMainThread = try #require(observedIsMainThread.read() as Bool?)
    #expect(isMainThread == true)
}
