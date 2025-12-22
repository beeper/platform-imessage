import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftServerFoundation

extension MessagesApplication {
    public struct ID: Hashable, Sendable {
        var rawValue = UUID()
        
        init() {
            
        }
    }
}

public final class MessagesApplication: @unchecked Sendable, ObservableObject {
    public static let bundleID: String = "com.apple.MobileSMS"
    public var publicInstance: NSRunningApplication? = nil
    
    @Published var pool: [ID: NSRunningApplication] = [:]
    
    public init() { }
    
    public func withPersistentRunningApplication(
        _ id: MessagesApplication.ID,
        url: URL?,
        action: @escaping @Sendable (NSRunningApplication) async throws -> Void
    ) async throws {
        var application: NSRunningApplication? = self.pool[id]
        
        if application == nil {
            application = try await Self.open(
                deepLink: url,
                shouldActivate: false,
                shouldHide: true
            )
            
            self.pool[id] = application
        }
        
        try await action(application!)
    }
    
    public func withHiddenRunningApplication(
        url: URL?,
        action: @escaping @Sendable (NSRunningApplication) async throws -> Void,
        terminationStatus: (@Sendable (NSRunningApplication, NSRunningApplication.TerminationResult) -> Void)? = nil
    ) async throws {
        let application: NSRunningApplication = try await Self.open(
            deepLink: url,
            shouldActivate: false,
            shouldHide: true
        )
        
        var thrownError: Error?
        
        do {
            try await action(application)
        } catch {
            thrownError = error
        }
        
        let result = await application.terminateAndWaitForTermination()
        
        await MainActor.run {
            terminationStatus?(application, result)
        }
        
        if let thrownError {
            throw thrownError
        }
    }
    
    @discardableResult
    public func terminateApplication(id: MessagesApplication.ID) async -> NSRunningApplication.TerminationResult {
        defer {
            pool.removeValue(forKey: id)
        }
        
        return await pool[id]?.terminateAndWaitForTermination() ?? .alreadyTerminated
    }
    
    @MainActor
    public static func open(
        deepLink: URL?,
        withinRunningApplication runningApplication: NSRunningApplication? = nil,
        shouldActivate: Bool = false,
        shouldHide: Bool = true,
        timeout: TimeInterval = 5
    ) async throws -> NSRunningApplication {
        guard let applicationURL: URL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw ErrorMessage("URL for \(bundleID) not found")
        }
        
        if let runningApplication, let deepLink {
            let appleEventDescriptor: NSAppleEventDescriptor = Self.appleEventDescriptor(deepLink: deepLink, target: runningApplication)
            try appleEventDescriptor.sendEvent(options: [.neverInteract, .waitForReply], timeout: timeout)
            
            return runningApplication
        } else {
            let openOptions = NSWorkspace.OpenConfiguration()
            
            openOptions.activates = shouldActivate
            openOptions.hides = shouldHide
            openOptions.createsNewApplicationInstance = (runningApplication == nil) ? true : false
            openOptions.addsToRecentItems = false
            openOptions.launchesInBackground = true
            openOptions.launchIsUserAction = true
            
            if let deepLink {
                openOptions.appleEvent = Self.appleEventDescriptor(deepLink: deepLink, target: runningApplication)
            }
            
            // test NSWorkspace.shared.open(at:)
            return try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: openOptions)
        }
    }
    
    @MainActor
    static func appleEventDescriptor(deepLink url: URL, target application: NSRunningApplication?) -> NSAppleEventDescriptor {
        let eventDescriptor: NSAppleEventDescriptor = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: application.flatMap { NSAppleEventDescriptor(processIdentifier: $0.processIdentifier) },
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        
        eventDescriptor.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )
        
        return eventDescriptor
    }
}

extension NSRunningApplication {
    public enum TerminationResult: Sendable, Equatable {
        case alreadyTerminated
        case terminatedGracefully
        case terminatedForcibly
        case failedToTerminate
    }
    
    public func terminateAndWaitForTermination(
        terminationTimeoutSeconds: TimeInterval = 2.0,
        forceTerminationTimeoutSeconds: TimeInterval = 2.0
    ) async -> TerminationResult {
        
        let isAlreadyTerminated = await MainActor.run { self.isTerminated }
        if isAlreadyTerminated { return .alreadyTerminated }
        
        await MainActor.run { _ = self.terminate() }
        
        let didTerminateGracefully = await waitForTerminationWithCombineTimeout(
            terminationTimeoutSeconds: terminationTimeoutSeconds
        )
        
        if didTerminateGracefully { return .terminatedGracefully }
        
        await MainActor.run { _ = self.forceTerminate() }
        
        let didTerminateForcibly = await waitForTerminationWithCombineTimeout(
            terminationTimeoutSeconds: forceTerminationTimeoutSeconds
        )
        
        if didTerminateForcibly { return .terminatedForcibly }
        
        return .failedToTerminate
    }
    
    private func waitForTerminationWithCombineTimeout(
        terminationTimeoutSeconds: TimeInterval
    ) async -> Bool {
        if self.isTerminated { return true }
        
        let terminationTimeoutStride = RunLoop.SchedulerTimeType.Stride
            .seconds(terminationTimeoutSeconds)
        
        let terminationStatePublisher = self
            .publisher(for: \.isTerminated, options: [.initial, .new])
            .removeDuplicates()
            .filter { $0 }
            .first()
            .timeout(
                terminationTimeoutStride,
                scheduler: RunLoop.main
            )
        
        var cancellableSubscription: AnyCancellable?
        
        return await withCheckedContinuation { continuation in
            cancellableSubscription = terminationStatePublisher.sink(
                receiveCompletion: { completion in
                    switch completion {
                        case .finished:
                            continuation.resume(returning: self.isTerminated)
                            cancellableSubscription?.cancel()
                            cancellableSubscription = nil
                        case .failure:
                            continuation.resume(returning: self.isTerminated)
                            cancellableSubscription?.cancel()
                            cancellableSubscription = nil
                    }
                },
                receiveValue: { _ in
                    continuation.resume(returning: true)
                    cancellableSubscription?.cancel()
                    cancellableSubscription = nil
                }
            )
        }
    }
}

