import AppKit
import AccessibilityControl
import Darwin
import IMessagePrivateSPI
import WindowControl
@testable import IMessage
import IMessageCore
import Testing

// Synchronous AppKit calls run on a worker while the main run loop delivers
// lifecycle notifications. Blocking the main thread leaves cached app state stale.
@MainActor
func runSmokeWorker<Value>(_ operation: @escaping () throws -> Value) throws -> Value {
    let result = Protected<Result<Value, Error>?>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let completed = Result(catching: operation)
        result.withLock { $0 = completed }
        done.signal()
    }
    while done.wait(timeout: .now()) != .success {
        pumpSmokeRunLoop(for: 0.01)
    }
    return try #require(result.read()).get()
}

@MainActor
func pumpSmokeRunLoop(for interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
func waitForSmoke(_ description: String = "live Messages state", timeout: TimeInterval = 5, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        pumpSmokeRunLoop(for: 0.02)
    }
    try #require(try condition(), Comment(rawValue: "Timed out waiting for \(description)"))
}

func smokeOnscreen(_ window: UInt32) throws -> Bool {
    try Window.listDescriptions(.onScreen).contains { $0.window.raw == window }
}

func smokeFrontmost(_ app: Accessibility.Element) throws -> Bool {
    try app.attribute(Accessibility.Attribute<Bool>.Name(kAXFrontmostAttribute))()
}

func smokeWindowSpaces(_ window: UInt32) throws -> [UInt64] {
    try #require(IMPrivateSPISpacesForWindow(window)?.map(\.uint64Value))
}

func smokePoolSpaceIDs() throws -> Set<UInt64> {
    var result = Set<UInt64>()
    for space in try Space.list(.allOSSpaces) {
        guard try space.kind() == .unknown else { continue }
        let values = try space.values() as NSDictionary
        if values["uuid"] as? String == PersistentUnknownSpace.uuid {
            #expect(values["ManagedSpaceID"] == nil)
            result.insert(UInt64(space.raw))
        }
    }
    return result
}

func smokeManagedSpaceIDs(currentOnly: Bool = false) throws -> Set<UInt64> {
    let topology = try #require(IMPrivateSPICopyManagedDisplaySpaces())
    try #require(!topology.isEmpty)
    return Set(topology.flatMap { display -> [UInt64] in
        let current = (display["Current Space"] as? [String: Any]).map { [$0] } ?? []
        let spaces = currentOnly ? current : (display["Spaces"] as? [[String: Any]] ?? []) + current
        return spaces.compactMap {
            ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? ($0["id64"] as? NSNumber)?.uint64Value
        }
    })
}

func smokeMessagesPIDs() -> Set<pid_t> {
    Set(NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).map(\.processIdentifier))
}

func smokeProcessExited(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}
