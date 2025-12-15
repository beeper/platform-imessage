import Foundation
import AppKit
import SwiftServer
import Testing

@Suite("New")
struct WithSynchronousWaitTests {
    @Test
    func returnsValueFromAsyncFunction() throws {
        let value = try withSynchronousWait {
            try await Task.sleep(nanoseconds: 50_000_000)
            return 42
        }
        
        #expect(value == 42)
    }
    
    @Test
    func openApplication() throws {
        let value = try withSynchronousWait {
            let identifier = "com.apple.MobileSMS"
            let url: URL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)!
            
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.allowsRunningApplicationSubstitution

            try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return 42
        }
        
        #expect(value == 42)
    }
    
    @Test
    func propagatesThrownError() {
        enum TestError: Error { case boom }
        
        #expect(throws: TestError.self) {
            try withSynchronousWait {
                try await Task.sleep(nanoseconds: 10_000_000)
                throw TestError.boom
            }
        }
    }
    
    @Test
    func runsOnProvidedQueue() throws {
        let queue = DispatchQueue(label: "test.queue")
        let key = DispatchSpecificKey<Void>()
        queue.setSpecific(key: key, value: ())
        
        let ranOnQueue = try withSynchronousWait(on: queue) {
            DispatchQueue.getSpecific(key: key) != nil
        }
        
        #expect(ranOnQueue == true)
    }
}



/// Bridges an async operation into a synchronous one by blocking the *current* thread until completion.
///
/// - Important:
///   - This is a hack
///   - Do **not** call this on the main thread.
///   - If you pass a **serial** `queue` and call this function **from that same queue**, you can deadlock.
@discardableResult
public func withSynchronousWait<T>(
    on queue: DispatchQueue? = nil,
    _ operation: @escaping () async throws -> T
) throws -> T {
    precondition(!Thread.isMainThread, "Do not block the main thread.")
    
    let semaphore = DispatchSemaphore(value: 0)
    
    var result: Result<T, Error>?
    
    let start: () -> Void = {
        Task.detached {
            let _result: Result<T, Error>
            
            
            do {
                _result = try await .success(operation())
            } catch {
                _result = .failure(error)
            }
            
            result = _result
            
            semaphore.signal()
        }
    }
    
    if let queue {
        queue.async(execute: start)
    } else {
        start()
    }
    
    semaphore.wait()
    
    lock.lock()
    let final = result!
    lock.unlock()
    
    return try final.get()
}
