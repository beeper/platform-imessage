import AppKit
import AccessibilityControl
import ApplicationServices
import Combine
import Foundation
import Logging
import LSLauncher
import SwiftServerFoundation

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
                return publicInstance?.runningApplication
            case .puppetInstance:
                return puppetInstance?.runningApplication
        }
    }
    
    public var runningApplications: [NSRunningApplication] {
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
    }
    
    var cancellables: Set<AnyCancellable> = []
    private var typeObserver: LSTypeObserver?
    private var suppressionSubject: PassthroughSubject<pid_t, Never> = .init()
    private var suppressionCancellable: AnyCancellable?

    // Border overlay windows for debugging
    var publicBorderWindow: NSWindow?
    var puppetBorderWindow: NSWindow?
    var windowEventCancellables: Set<AnyCancellable> = []

    public init(strategy: Strategy = .puppetInstance, useExtantInstanceIfPossible: Bool = true) async throws {
        self.pool = [:]
        self.strategy = strategy

        Self.logger.info("[init] starting (strategy=\(strategy), useExtant=\(useExtantInstanceIfPossible), existingCount=\(runningApplications.count))")
        for (idx, app) in runningApplications.enumerated() {
            Self.logStatus(app, context: "init.existing[\(idx)]")
        }

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
            Self.logger.info("[init] launching puppet instance (shouldHide=\(Defaults.shouldHidePuppetInstance))")
            // Default to hiding the puppet instance unless explicitly set to false
            self.puppetInstance = try await Self.open(
                deepLink: nil,
                shouldActivate: false,
                shouldHide: Defaults.shouldHidePuppetInstance,
                launchesInBackground: Defaults.shouldHidePuppetInstance
            )
            Self.logStatus(puppetInstance!.runningApplication, context: "init.puppetInstance.afterOpen")
            pool[puppetInstance!.id] = puppetInstance!

            if Defaults.shouldHidePuppetInstance {
                startAutoSuppress()
            }
        }

        assert(controlledRunningApplication != nil)

        // Observe settings changes for live updates
        await MainActor.run {
            observeBorderOverlaySetting()
        }
        observeHidePuppetInstanceSetting()

        // Show deep link debug window on launch if enabled
        if #available(macOS 14, *) {
            await MainActor.run {
                DeepLinkDebugWindowController.showOnLaunchIfNeeded()
            }
        }
    }

    deinit {
        stopAutoSuppress()
        // Clean up border windows - needs to be done on main thread
        let publicWindow = publicBorderWindow
        let puppetWindow = puppetBorderWindow
        DispatchQueue.main.async {
            publicWindow?.close()
            puppetWindow?.close()
        }
        cancellables.removeAll()
        windowEventCancellables.removeAll()
    }
    
    private static func launchPublicInstance() async throws -> Instance {

        let instance: Instance = try await Self.open(deepLink: nil, shouldHide: false, launchesInBackground: false)
        Self.logStatus(instance.runningApplication, context: "launchPublicInstance.afterOpen")

        try? instance.runningApplication.elements.mainWindow.setFrame(CGRect(x: 700, y: 700, width: 550, height: 500))
        Self.logStatus(instance.runningApplication, context: "launchPublicInstance.afterSetFrame")

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
    
    /// Whether the puppet instance is currently being auto-suppressed
    public var isAutoSuppressing: Bool {
        typeObserver?.isObserving ?? false
    }

    /// Starts observing application mode changes and automatically suppresses the puppet instance
    /// when it tries to become a foreground application.
    public func startAutoSuppress() {
        guard strategy == .puppetInstance else {
            Self.logger.warning("Auto-suppress is only available when using puppet instance strategy")
            return
        }

        guard typeObserver == nil else {
            Self.logger.debug("Auto-suppress already active")
            return
        }

        suppressionCancellable = suppressionSubject
            .debounce(for: .milliseconds(10000), scheduler: DispatchQueue.main)
            .sink { [weak self] pid in
                guard let self else { return }

                Self.logger.debug("[Suppression] Debounced suppression triggered for pid=\(pid)")

                // Suppress the controlled running application
                do {
                    try self.controlledRunningApplication.suppress()
                    Self.logger.debug("[Suppression] Successfully suppressed controlledRunningApplication")

                    // Record suppression for debug view
                    if #available(macOS 14, *) {
                        DeepLinkDebugManager.shared.recordSuppression(instancePID: pid)
                    }
                } catch {
                    Self.logger.error("[Suppression] Failed to suppress puppet instance: \(error)")
                }
            }

        let observer = LSTypeObserver()
        observer.startObserving { [weak self] bundleID, pid, oldType, newType in
            guard let self else { return }

            Self.logger.debug("[TypeChange] bundleID=\(bundleID ?? "nil") pid=\(pid) oldType=\(oldType?.rawValue ?? "nil") newType=\(newType?.rawValue ?? "nil") publicPID=\(self.publicInstance?.pid ?? -1) puppetPID=\(self.puppetInstance?.pid ?? -1)")

            // Only handle transitions TO Foreground
            guard newType == .foreground else {
                Self.logger.debug("[TypeChange] Ignoring: newType is \(newType?.rawValue ?? "nil"), not Foreground")
                return
            }

            // Never suppress the public instance
            guard pid != self.publicInstance?.pid else {
                Self.logger.debug("[TypeChange] Ignoring foreground transition for public instance (pid: \(pid))")
                return
            }

            Self.logger.debug("[TypeChange] Puppet instance (pid: \(pid)) became foreground, sending to suppression subject...")

            // Send to debounced subject instead of suppressing immediately
            self.suppressionSubject.send(pid)
        }

        typeObserver = observer
        Self.logger.info("Started auto-suppress for puppet instance (public pid: \(self.publicInstance?.pid ?? -1))")
    }

    /// Stops auto-suppressing the puppet instance
    public func stopAutoSuppress() {
        guard let observer = typeObserver else {
            return
        }

        observer.stopObserving()
        typeObserver = nil

        suppressionCancellable?.cancel()
        suppressionCancellable = nil

        Self.logger.info("Stopped auto-suppress for puppet instance")
    }

    private func observeHidePuppetInstanceSetting() {
        // Only relevant for puppet instance strategy
        guard strategy == .puppetInstance else { return }

        // Track current state to detect changes
        var currentValue = Defaults.swiftServer.bool(forKey: DefaultsKeys.hidePuppetInstance)

        // Observe changes via NotificationCenter
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: Defaults.swiftServer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard let puppetApp = self.puppetInstance?.runningApplication else { return }

                let newValue = Defaults.swiftServer.bool(forKey: DefaultsKeys.hidePuppetInstance)
                guard newValue != currentValue else { return }
                currentValue = newValue

                if newValue {
                    Self.logger.info("Hide puppet instance enabled, starting auto-suppress")
                    self.startAutoSuppress()
                    do {
                        try puppetApp.suppress()
                        Self.logger.info("Successfully suppressed puppet instance")
                    } catch {
                        Self.logger.error("Failed to suppress puppet instance: \(error)")
                    }
                } else {
                    // Hiding disabled: stop auto-suppression first, then promote to foreground
                    Self.logger.info("Hide puppet instance disabled, stopping auto-suppress and promoting")
                    self.stopAutoSuppress()
                    do {
                        try puppetApp.promote()
                        Self.logger.info("Successfully promoted puppet instance to foreground")
                    } catch {
                        Self.logger.error("Failed to promote puppet instance: \(error)")
                    }
                }
            }
            .store(in: &cancellables)
    }

    private static func sendDeepLink(
        _ url: URL,
        to runningApplication: NSRunningApplication,
        timeout: TimeInterval = 5
    ) throws {
        let appleEventDescriptor = appleEventDescriptor(deepLink: url, target: runningApplication)
        try appleEventDescriptor.sendEvent(options: [.neverInteract, .waitForReply], timeout: timeout)
    }

    /// Launches a new application instance (async)
    @MainActor
    private static func launchNewInstance(
        applicationURL: URL,
        deepLink: URL?,
        shouldActivate: Bool,
        shouldHide: Bool,
        launchesInBackground: Bool
    ) async throws -> NSRunningApplication {
        let openOptions = NSWorkspace.OpenConfiguration()

        openOptions.activates = shouldActivate
        openOptions.hides = shouldHide
        openOptions.createsNewApplicationInstance = true
        openOptions.allowsRunningApplicationSubstitution = false
        openOptions.addsToRecentItems = false
        openOptions.launchesInBackground = launchesInBackground
        openOptions.launchIsUserAction = true

        if let deepLink {
            openOptions.appleEvent = appleEventDescriptor(deepLink: deepLink, target: nil)
        }

        return try await NSWorkspace.shared.open(applicationURL, configuration: openOptions)
    };

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
        Self.logger.debug("MessagesApplication.open [launchesInBackground: \(launchesInBackground)]")
        Self.logger.info("[open] starting (deepLink=\(deepLink != nil), launchesInBackground=\(launchesInBackground))")
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ErrorMessage("URL for \(bundleID) not found")
        }

        let finalRunningApplication: NSRunningApplication

        if let runningApplication, let deepLink {
            Self.logStatus(runningApplication, context: "open.beforeSendDeepLink")
            try sendDeepLink(deepLink, to: runningApplication, timeout: timeout)
            Self.logStatus(runningApplication, context: "open.afterSendDeepLink")
            finalRunningApplication = runningApplication
        } else {
            finalRunningApplication = try await launchNewInstance(
                applicationURL: applicationURL,
                deepLink: deepLink,
                shouldActivate: shouldActivate,
                shouldHide: shouldHide,
                launchesInBackground: launchesInBackground
            )
            Self.logStatus(finalRunningApplication, context: "open.afterLaunchNewInstance")
        }

        if launchesInBackground {
            Self.logStatus(finalRunningApplication, context: "open.beforeSuppress")
            Self.logStatus(finalRunningApplication, context: "open.afterSuppress")
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
        hiding: Bool = true,
        timeout: TimeInterval = 5
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
            Self.logger.debug("OPENING DEEP LINK: \(url) (activating? \(activating), hiding? \(hiding))")
        } else {
            Self.logger.debug("OPENING DEEP LINK (activating? \(activating), hiding? \(hiding))")
        }

        Self.logStatus(runningApplication, context: "openDeepLink.beforeSend")

        // Record deep link event for debug view
        let pid = runningApplication.processIdentifier
        
        if #available(macOS 14, *) {
            DeepLinkDebugManager.shared.recordDeepLinkOpened(instancePID: pid, url: url)
            DeepLinkDebugManager.shared.updateInstances(
                publicPID: self.publicInstance?.pid,
                puppetPID: self.puppetInstance?.pid,
                totalCount: self.pool.count
            )
        }

        try Self.sendDeepLink(url, to: runningApplication, timeout: timeout)
        Self.logStatus(runningApplication, context: "openDeepLink.afterSend")

        if activating {
            runningApplication.activate()
            Self.logStatus(runningApplication, context: "openDeepLink.afterActivate")
        }

        if hiding {
            runningApplication.hide()
            Self.logStatus(runningApplication, context: "openDeepLink.afterHide")

            // Record suppression for debug view
            if #available(macOS 14, *) {
                DeepLinkDebugManager.shared.recordSuppression(instancePID: pid)
            }
        }

        return runningApplication
    }
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

// MARK: - Logging

@available(macOS 11, *)
extension MessagesApplication {
    static let logger = Logger(swiftServerLabel: "messages-application")

    /// Logs the current application mode for debugging dock icon / UIElement issues
    static func logStatus(
        _ app: NSRunningApplication,
        context: String,
        file: String = #file,
        line: Int = #line
    ) {
        let mode = app.applicationMode?.rawValue ?? "unknown"
        let pid = app.processIdentifier
        let isHidden = app.isHidden
        let isActive = app.isActive
        let isFinished = app.isFinishedLaunching
        
        logger.info("[\(context)] pid=\(pid) mode=\(mode) hidden=\(isHidden) active=\(isActive) finished=\(isFinished)")
    }
}
