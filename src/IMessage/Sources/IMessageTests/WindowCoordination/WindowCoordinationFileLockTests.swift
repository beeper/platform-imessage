import Foundation
import Testing
@testable import IMessage

@Test
func windowCoordinationFileLockRejectsConcurrentOwner() throws {
    let name = "test-conflict-\(UUID().uuidString)"
    let first = try WindowCoordinationFileLock(name: name)
    try withExtendedLifetime(first) {
        do {
            _ = try WindowCoordinationFileLock(name: name, wait: false)
            Issue.record("A second owner must not acquire the same lock")
        } catch WindowCoordinatorError.instanceInUse {
            // This specific error lets a borrowing controller preserve Messages.
        }
    }
}

@Test
func windowCoordinationFileLockAllowsIndependentNames() throws {
    let prefix = "test-independent-\(UUID().uuidString)"
    let first = try WindowCoordinationFileLock(name: prefix + "-one", wait: false)
    let second = try WindowCoordinationFileLock(name: prefix + "-two", wait: false)
    withExtendedLifetime((first, second)) {}
}

@Test
func windowCoordinationFileLockReleasesForNextOwner() throws {
    let name = "test-release-\(UUID().uuidString)"
    var first: WindowCoordinationFileLock? = try WindowCoordinationFileLock(name: name, wait: false)
    weak var released = first
    #expect(first != nil)
    first = nil
    #expect(released == nil)
    let next = try WindowCoordinationFileLock(name: name, wait: false)
    withExtendedLifetime(next) {}
}
