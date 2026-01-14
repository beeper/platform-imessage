import AppKit
import ApplicationServices
import Combine
import Foundation
import Logging
import LSLauncher
import SwiftServerFoundation

private let log = Logger(swiftServerLabel: "messages-application")

@available(macOS 11, *)
extension MessagesApplication {
    public struct ID: Hashable, Sendable {
        var rawValue = UUID()
        
        init() {
            
        }
    }
    
    public class Instance: Identifiable, @unchecked Sendable {
        public var id: ID
        public var runningApplication: NSRunningApplication
        
        public var pid: pid_t {
            runningApplication.processIdentifier
        }
        
        init(id: ID? = nil, runningApplication: NSRunningApplication) {
            self.id = id ?? ID()
            self.runningApplication = runningApplication
        }
        
        public static func createInstances() -> [Instance] {
            NSRunningApplication.runningApplications(withBundleIdentifier: MessagesApplication.bundleID).map { Instance(runningApplication: $0) }
        }
    }
}

// TODO: (@pmanot) - Rename
@available(macOS 11, *)
public final class MessagesApplication: @unchecked Sendable, ObservableObject {
    public static let bundleID: String = "com.apple.MobileSMS"
    
    public let strategy: Strategy
    
    public var publicInstance: Instance? = nil
    public var puppetInstance: Instance? = nil
    public var alwaysKeepPublicInstanceAlive: Bool = true
    
    @Published
    var pool: [ID: Instance] = [:]
    private var pidMap: [pid_t: ID] = [:]
    
    public var controlledRunningApplication: NSRunningApplication! {
        switch strategy {
            case .publicInstance:
                publicInstance?.runningApplication
            case .puppetInstance:
                puppetInstance?.runningApplication
        }
    }
    
    public var runningApplications: [NSRunningApplication] {
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
    }
    
    private var cancellables: Set<AnyCancellable> = []
    private var instanceBorderOverlay: InstanceBorderOverlay?

    public init(strategy: Strategy = .puppetInstance, useExtantInstanceIfPossible: Bool = true) async throws {
        self.pool = [:]
        self.strategy = strategy
        
        // TODO: (@pmanot) - reduce code duplication and refactor
        switch runningApplications.count {
            case 1:
                if useExtantInstanceIfPossible {
                    assert(runningApplications.count == 1)
                    let instance: Instance = Instance(runningApplication: runningApplications[0])
                    pool[instance.id] = instance
                } else {
                    fallthrough
                }
            default:
                for runningApp in runningApplications {
                    // TODO: handle termination failures
                    _ = await runningApp.terminateAndWaitForTermination()
                }
                
                
                let instance: Instance = try await MessagesApplication.launchPublicInstance()
                pool[instance.id] = instance
        }
        
        assert(pool.count == 1)
        assert(runningApplications.count == 1)
        publicInstance = pool.first!.value
        
//        if alwaysKeepPublicInstanceAlive {
//            relaunchPublicInstanceOnTermination()
//        }
        
        if strategy == .puppetInstance {
            // Default to hiding the puppet instance unless explicitly set to false
            self.puppetInstance = try await Self.open(
                deepLink: nil,
                shouldActivate: false,
                shouldHide: Defaults.shouldHidePuppetInstance,
                launchesInBackground: Defaults.shouldHidePuppetInstance
            )
            pool[puppetInstance!.id] = puppetInstance!
        }

        assert(controlledRunningApplication != nil)

        // Start instance border overlay - it will check the defaults setting itself
        await MainActor.run {
            instanceBorderOverlay = InstanceBorderOverlay(messagesApplication: self)
            instanceBorderOverlay?.start()
        }
    }

    deinit {
        instanceBorderOverlay?.stop()
        cancellables.removeAll()
    }
    
    private static func launchPublicInstance() async throws -> Instance {
        let instance: Instance = try await Self.open(deepLink: nil, shouldHide: false, launchesInBackground: false)
        
        try? instance.runningApplication.elements.mainWindow.setFrame(CGRect(x: 700, y: 700, width: 550, height: 500))
        
        return instance
    }
    
    public func relaunchPublicInstanceOnTermination() {
        cancellables.removeAll()
        
        if let instance: Instance = self.publicInstance, instance.runningApplication.isTerminated {
            Task { @MainActor [weak self] in
                self?.publicInstance = try await Self.launchPublicInstance()
                
                self?.relaunchPublicInstanceOnTermination()
            }
        } else {
            self.publicInstance?.runningApplication.publisher(for: \.isTerminated)
                .sink { [weak self] isTerminated in
                    if isTerminated {
                        self?.relaunchPublicInstanceOnTermination()
                        
                        self?.cancellables.removeAll()
                    }
                }
                .store(in: &cancellables)
        }
    }
    
    private func observeRunningApplications() {
        NSWorkspace.shared.publisher(for: \.runningApplications).sink { [weak self] _ in
            guard let self else { return }
            
            for runningApplication in self.runningApplications {
                if !self.pool.contains(where: { (key, value) in
                    return value.runningApplication == runningApplication
                }) {
                    let instance: Instance = Instance(runningApplication: runningApplication)
                    self.pool[instance.id] = instance
                }
            }
        }
        .store(in: &cancellables)
    }
    
    public func withPersistentRunningApplication(
        _ id: MessagesApplication.ID,
        url: URL?,
        action: @escaping @Sendable (NSRunningApplication) async throws -> Void
    ) async throws {
        var application: MessagesApplication.Instance? = self.pool[id]
        
        if application == nil {
            application = try await Self.open(
                deepLink: url,
                shouldActivate: false,
                shouldHide: true,
                launchesInBackground: false
            )
            
            self.pool[id] = application
        }
        
        try await action(application!.runningApplication)
    }
    
    public func withHiddenRunningApplication(
        url: URL?,
        action: @escaping @Sendable (NSRunningApplication) async throws -> Void,
        terminationStatus: (@Sendable (NSRunningApplication, NSRunningApplication.TerminationResult) -> Void)? = nil
    ) async throws {
        let instance: Instance = try await Self.open(
            deepLink: url,
            shouldActivate: false,
            shouldHide: true,
            launchesInBackground: false
        )
        
        var thrownError: Error?
        
        do {
            try await action(instance.runningApplication)
        } catch {
            thrownError = error
        }
        
        let result = await instance.runningApplication.terminateAndWaitForTermination()
        
        await MainActor.run {
            terminationStatus?(instance.runningApplication, result)
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
        
        return await pool[id]?.runningApplication.terminateAndWaitForTermination() ?? .alreadyTerminated
    }
    
    @MainActor
    @discardableResult
    private static func open(
        deepLink: URL?,
        withinRunningApplication runningApplication: NSRunningApplication? = nil,
        shouldActivate: Bool = false,
        shouldHide: Bool = true,
        launchesInBackground: Bool,
        timeout: TimeInterval = 5
    ) async throws -> MessagesApplication.Instance {
        guard let applicationURL: URL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw ErrorMessage("URL for \(bundleID) not found")
        }
        
        let finalRunningApplication: NSRunningApplication
        
        if let runningApplication, let deepLink {
            let appleEventDescriptor: NSAppleEventDescriptor = Self.appleEventDescriptor(deepLink: deepLink, target: runningApplication)
            try appleEventDescriptor.sendEvent(options: [.neverInteract, .waitForReply], timeout: timeout)
            
            finalRunningApplication = runningApplication
        } else {
            let openOptions = NSWorkspace.OpenConfiguration()
            
            openOptions.activates = shouldActivate
            openOptions.hides = shouldHide
            openOptions.createsNewApplicationInstance = true
            openOptions.addsToRecentItems = false
            openOptions.uiElementLaunch = launchesInBackground
            openOptions.launchIsUserAction = true
            
            if let deepLink {
                openOptions.appleEvent = Self.appleEventDescriptor(deepLink: deepLink, target: runningApplication)
            }
            
            // test NSWorkspace.shared.open(at:)
            finalRunningApplication = try await NSWorkspace.shared.open(applicationURL, configuration: openOptions)
        }
        if launchesInBackground {
            try finalRunningApplication.suppress()
        }
                
        return Instance(runningApplication: finalRunningApplication)
    }
    
    @discardableResult
    public static func _openSynchronously(
        deepLink: URL?,
        withinRunningApplication runningApplication: NSRunningApplication? = nil,
        shouldActivate: Bool = false,
        shouldHide: Bool = true,
        launchesInBackground: Bool = false,
        timeout: TimeInterval = 5
    ) throws -> MessagesApplication.Instance {
        try unsafeBlockCurrentThreadUntilComplete {
            try await open(
                deepLink: deepLink,
                withinRunningApplication: runningApplication,
                shouldActivate: shouldActivate,
                shouldHide: shouldHide,
                launchesInBackground: launchesInBackground,
                timeout: timeout
            )
        }
    }
    
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
    
    // FIXME: (@pmanot) - unimplemented
    func terminate() {
        fatalError()
    }

    @discardableResult
    public func openDeepLink(
        _ url: URL,
        activating: Bool = false,
        hiding: Bool = true
    ) throws -> NSRunningApplication {
        guard let runningApplication = controlledRunningApplication else {
            throw ErrorMessage("No controlled running application")
        }

#if DEBUG
        let builtForDebugging = true
#else
        let builtForDebugging = false
#endif
        if SwiftServerDefaults[\.deepLinkTracingPII] || builtForDebugging {
            log.debug("OPENING DEEP LINK: \(url) (activating? \(activating), hiding? \(hiding))")
        } else {
            log.debug("OPENING DEEP LINK (activating? \(activating), hiding? \(hiding))")
        }

        Self.open(
            deepLink: url,
            withinRunningApplication: controlledRunningApplication,
            shouldActivate: false,
            shouldHide: Defaults.shouldHidePuppetInstance,
            launchesInBackground: hiding
        )
}

@available(macOS 11, *)
extension MessagesApplication {
    public enum Strategy: String, Codable {
        case publicInstance
        case puppetInstance
    }
}

// MARK: - Auxiliary

@available(macOS 11, *)
extension MessagesApplication.Instance {
    public func press(key: CGKeyCode, flags: CGEventFlags? = nil) throws {
        try self.runningApplication.press(key: key, flags: flags)
    }
    
    public func press(_ combo: KeyPresser.Combo) throws {
        try self.runningApplication.press(combo)
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

