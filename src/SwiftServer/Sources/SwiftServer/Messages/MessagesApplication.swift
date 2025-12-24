import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftServerFoundation

@available(macOS 11, *)
extension MessagesApplication {
    public struct ID: Hashable, Sendable {
        var rawValue = UUID()
        
        init() {
            
        }
    }
}

// TODO: (@pmanot) - Rename
@available(macOS 11, *)
public final class MessagesApplication: @unchecked Sendable, ObservableObject {
    public static let bundleID: String = "com.apple.MobileSMS"
    public var publicInstance: NSRunningApplication? = nil
    public var puppetInstance: NSRunningApplication
    public var puppetID: ID
    
    public var alwaysKeepPublicInstanceAlive: Bool = true
    
    @Published var pool: [ID: NSRunningApplication] = [:]
    
    private var cancellables: Set<AnyCancellable> = []
    
    public init() async throws {
        publicInstance = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        
        if publicInstance == nil {
            publicInstance = try await MessagesApplication.launchPublicInstance()
        }
        
        puppetInstance = try await Self.open(deepLink: nil, shouldActivate: false, shouldHide: true)
        puppetID = ID()
        
        pool[puppetID] = puppetInstance
        
        if alwaysKeepPublicInstanceAlive {
            relaunchPublicInstanceOnTermination()
        }
    }
    
    private static func launchPublicInstance() async throws -> NSRunningApplication {
        let application = try await Self.open(deepLink: nil, shouldHide: true, launchesInBackgound: false)
        
        try? application.elements.mainWindow.setFrame(CGRect(x: 700, y: 700, width: 550, height: 500))
        
        return application
    }
    
    public func relaunchPublicInstanceOnTermination() {
        cancellables.removeAll()
        
        if let application = self.publicInstance, application.isTerminated {
            Task { [weak self] in
                self?.publicInstance = try await Self.launchPublicInstance()
                
                self?.relaunchPublicInstanceOnTermination()
            }
        } else {
            self.publicInstance?.publisher(for: \.isTerminated)
                .sink { [weak self] isTerminated in
                    if isTerminated {
                        self?.relaunchPublicInstanceOnTermination()
                        
                        self?.cancellables.removeAll()
                    }
                }
                .store(in: &cancellables)
        }
    }
    
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
    @discardableResult
    public static func open(
        deepLink: URL?,
        withinRunningApplication runningApplication: NSRunningApplication? = nil,
        shouldActivate: Bool = false,
        shouldHide: Bool = true,
        launchesInBackgound: Bool = true,
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
            openOptions.createsNewApplicationInstance = true
            openOptions.addsToRecentItems = false
            openOptions.launchesInBackground = launchesInBackgound
            openOptions.launchIsUserAction = true
            
            if let deepLink {
                openOptions.appleEvent = Self.appleEventDescriptor(deepLink: deepLink, target: runningApplication)
            }
            
            // test NSWorkspace.shared.open(at:)
            return try await NSWorkspace.shared.open(applicationURL, configuration: openOptions)
        }
    }
    
    @discardableResult
    public static func _openSynchronously(
        deepLink: URL?,
        withinRunningApplication runningApplication: NSRunningApplication? = nil,
        shouldActivate: Bool = false,
        shouldHide: Bool = true,
        timeout: TimeInterval = 5
    ) throws -> NSRunningApplication {
        try unsafeBlockCurrentThreadUntilComplete {
            try await open(deepLink: deepLink, withinRunningApplication: runningApplication, shouldActivate: shouldActivate, shouldHide: shouldHide, timeout: timeout)
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
    
    // FIXME: (@pmanot) - this is temporary and fragile, replace with `terminateAndWaitForTermination` after testing
    func terminate() {
        self.puppetInstance.terminate()
    }
}


// MARK: - Auxiliary

@available(macOS 11, *)
extension MessagesApplication {
    public func press(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        try self.puppetInstance.press(key: key, flags: flags)
    }
    
    public func press(_ combo: KeyPresser.Combo) throws {
        try puppetInstance.press(combo)
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

