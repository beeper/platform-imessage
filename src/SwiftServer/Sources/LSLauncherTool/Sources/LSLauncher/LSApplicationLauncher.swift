import Foundation
import AppKit
import Darwin
import Carbon.HIToolbox

// MARK: - LSApplicationLauncher

/// A powerful application launcher that provides access to private LaunchServices APIs
/// for advanced control over application launching and runtime behavior.
///
/// ## Features
/// - Launch applications in different modes (foreground, UIElement, background)
/// - Synchronous launching that waits for applications to be fully ready
/// - Suppress running applications (hide from dock)
/// - Query and modify application visibility at runtime
///
/// ## Usage
/// ```swift
/// let launcher = LSApplicationLauncher.shared
///
/// // Launch an app synchronously
/// let result = try launcher.launch(bundleIdentifier: "com.apple.Safari", configuration: .synchronous)
///
/// // Suppress an app (hide from dock)
/// try launcher.suppress(app)
///
/// // Promote back to foreground
/// try launcher.promote(app)
/// ```
public final class LSApplicationLauncher: @unchecked Sendable {

    /// Shared singleton instance
    public static let shared = LSApplicationLauncher()

    // MARK: - Private API Handles

    private let handle: UnsafeMutableRawPointer
    private let bundle: CFBundle

    private let _LSASNCreateWithPid: LSASNCreateWithPidFn
    private let _LSASNToUInt64: LSASNToUInt64Fn
    private let _LSCopyApplicationInformationItem: LSCopyApplicationInformationItemFn
    private let _LSSetApplicationInformationItem: LSSetApplicationInformationItemFn
    private let _LSCopyRunningApplicationArray: LSCopyRunningApplicationArrayFn
    private let _LSCopyFrontApplication: LSCopyFrontApplicationFn
    private let _LSOpenURLsWithCompletionHandler: LSOpenURLsWithCompletionHandlerFn
    private let _LSOpenURLsUsingASNWithCompletionHandler: LSOpenURLsUsingASNWithCompletionHandlerFn
    private let _LSOpenURLsUsingBundleIdentifierWithCompletionHandler: LSOpenURLsUsingBundleIdentifierWithCompletionHandlerFn

    // Notification functions
    let _LSScheduleNotificationOnQueueWithBlock: LSScheduleNotificationOnQueueWithBlockFn
    let _LSModifyNotification: LSModifyNotificationFn
    let _LSUnscheduleNotificationFunction: LSUnscheduleNotificationFunctionFn

    private let kLSApplicationTypeKey: CFString
    private let kLSApplicationTypeToRestoreKey: CFString
    let kLSApplicationUIElementTypeKey: CFString

    private var optionKeys: [String: CFString] = [:]

    // MARK: - Initialization

    private init() {
        let launchServicesPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices"

        guard let h = dlopen(launchServicesPath, RTLD_NOW) else {
            fatalError("Failed to open LaunchServices: \(String(cString: dlerror()))")
        }
        self.handle = h

        guard let b = CFBundleGetBundleWithIdentifier("com.apple.LaunchServices" as CFString) ??
              CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: launchServicesPath) as CFURL) else {
            fatalError("Failed to get LaunchServices bundle")
        }
        self.bundle = b

        func loadFunc<T>(_ name: String) -> T {
            guard let sym = dlsym(h, name) else {
                fatalError("Failed to load symbol: \(name)")
            }
            return unsafeBitCast(sym, to: T.self)
        }

        _LSASNCreateWithPid = loadFunc("_LSASNCreateWithPid")
        _LSASNToUInt64 = loadFunc("_LSASNToUInt64")
        _LSCopyApplicationInformationItem = loadFunc("_LSCopyApplicationInformationItem")
        _LSSetApplicationInformationItem = loadFunc("_LSSetApplicationInformationItem")
        _LSCopyRunningApplicationArray = loadFunc("_LSCopyRunningApplicationArray")
        _LSCopyFrontApplication = loadFunc("_LSCopyFrontApplication")
        _LSOpenURLsWithCompletionHandler = loadFunc("_LSOpenURLsWithCompletionHandler")
        _LSOpenURLsUsingASNWithCompletionHandler = loadFunc("_LSOpenURLsUsingASNWithCompletionHandler")
        _LSOpenURLsUsingBundleIdentifierWithCompletionHandler = loadFunc("_LSOpenURLsUsingBundleIdentifierWithCompletionHandler")

        // Notification functions
        _LSScheduleNotificationOnQueueWithBlock = loadFunc("_LSScheduleNotificationOnQueueWithBlock")
        _LSModifyNotification = loadFunc("_LSModifyNotification")
        _LSUnscheduleNotificationFunction = loadFunc("_LSUnscheduleNotificationFunction")

        func loadString(_ name: String) -> CFString {
            if let str = Self.loadCFStringGlobal(bundle: b, symbol: "_\(name)") {
                return str
            }
            if let str = Self.loadCFStringGlobal(bundle: b, symbol: name) {
                return str
            }
            fatalError("Failed to load CFString: \(name)")
        }

        kLSApplicationTypeKey = loadString("kLSApplicationTypeKey")
        kLSApplicationTypeToRestoreKey = loadString("kLSApplicationTypeToRestoreKey")
        kLSApplicationUIElementTypeKey = loadString("kLSApplicationUIElementTypeKey")

        let optionKeyNames = [
            "kLSOpenOptionSynchronousKey",
            "kLSOpenOptionForegroundLaunchKey",
            "kLSOpenOptionUIElementLaunchKey",
            "kLSOpenOptionBackgroundLaunchKey",
            "kLSOpenOptionHideKey",
            "kLSOpenOptionActivateKey",
            "kLSOpenOptionPreferRunningInstanceKey",
            "kLSOpenOptionArgumentsKey",
            "kLSOpenOptionEnvironmentVariablesKey",
            "kLSOpenOptionWaitForApplicationToCheckInKey",
            "kLSOpenOptionLaunchWithoutRestoringStateKey",
        ]

        for name in optionKeyNames {
            if let key = Self.loadCFStringGlobal(bundle: b, symbol: "_\(name)") {
                optionKeys[name] = key
            }
        }
    }

    private static func loadCFStringGlobal(bundle: CFBundle, symbol: String) -> CFString? {
        guard let raw = CFBundleGetDataPointerForName(bundle, symbol as CFString) else { return nil }
        let p = raw.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        guard let objPtr = p else { return nil }
        return unsafeBitCast(objPtr, to: CFString.self)
    }

    // MARK: - ASN Management

    /// Create an Application Serial Number for a process ID
    public func createASN(pid: pid_t) -> LSASN? {
        return _LSASNCreateWithPid(nil, pid)
    }

    /// Get the ASN for a running application
    public func getASN(for app: NSRunningApplication) -> LSASN? {
        return createASN(pid: app.processIdentifier)
    }

    /// Convert an ASN to its UInt64 representation
    public func asnToUInt64(_ asn: LSASN) -> UInt64 {
        return _LSASNToUInt64(asn)
    }

    // MARK: - Application Information

    /// Get information about an application
    public func getApplicationInfo(asn: LSASN, key: CFString, sessionID: Int32 = kLSDefaultSessionID) -> CFTypeRef? {
        return _LSCopyApplicationInformationItem(sessionID, asn, key)
    }

    /// Set information for an application
    @discardableResult
    public func setApplicationInfo(asn: LSASN, key: CFString, value: CFTypeRef?, sessionID: Int32 = kLSDefaultSessionID) -> OSStatus {
        return _LSSetApplicationInformationItem(sessionID, asn, key, value, nil)
    }

    // MARK: - Application Mode

    /// Get the current application mode (foreground, UIElement, or background)
    public func getApplicationMode(for app: NSRunningApplication) -> ApplicationMode? {
        guard let asn = getASN(for: app),
              let typeRef = getApplicationInfo(asn: asn, key: kLSApplicationTypeKey),
              let typeString = typeRef as? String else {
            return nil
        }
        return ApplicationMode(rawValue: typeString)
    }

    /// Set the application mode
    @discardableResult
    public func setApplicationMode(for app: NSRunningApplication, to mode: ApplicationMode) -> OSStatus {
        guard let asn = getASN(for: app) else {
            return OSStatus(kLSApplicationNotFoundErr)
        }

        let modeString: CFString
        switch mode {
        case .foreground:
            modeString = "Foreground" as CFString
        case .uiElement:
            modeString = kLSApplicationUIElementTypeKey
        case .backgroundOnly:
            modeString = "BackgroundOnly" as CFString
        }

        let r1 = setApplicationInfo(asn: asn, key: kLSApplicationTypeToRestoreKey, value: modeString)
        let r2 = setApplicationInfo(asn: asn, key: kLSApplicationTypeKey, value: modeString)

        return r1 != noErr ? r1 : r2
    }

    // MARK: - Suppression (Convenience Methods)

    /// Suppress an application (hide it from the dock by making it a UIElement)
    /// - Parameter app: The running application to suppress
    /// - Throws: `LaunchError` if the operation fails
    public func suppress(_ app: NSRunningApplication) throws {
        let status = setApplicationMode(for: app, to: .uiElement)
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Suppress an application to background mode (no dock, no UI)
    /// - Parameter app: The running application to suppress
    /// - Throws: `LaunchError` if the operation fails
    public func suppressToBackground(_ app: NSRunningApplication) throws {
        let status = setApplicationMode(for: app, to: .backgroundOnly)
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Promote an application back to foreground (show in dock)
    /// - Parameter app: The running application to promote
    /// - Throws: `LaunchError` if the operation fails
    public func promote(_ app: NSRunningApplication) throws {
        let status = setApplicationMode(for: app, to: .foreground)
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // MARK: - Launching

    /// Launch an application by bundle identifier
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier of the application to launch
    ///   - configuration: Launch configuration options
    /// - Returns: The result containing the running application
    public func launch(
        bundleIdentifier: String,
        configuration: LaunchConfiguration = .default
    ) throws -> LaunchResult {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw LaunchError.applicationNotFound(bundleIdentifier)
        }
        return try launch(at: appURL, configuration: configuration)
    }

    /// Launch an application at a URL
    /// - Parameters:
    ///   - url: The file URL of the application bundle
    ///   - configuration: Launch configuration options
    /// - Returns: The result containing the running application
    public func launch(
        at url: URL,
        configuration: LaunchConfiguration = .default
    ) throws -> LaunchResult {
        let startTime = Date()

        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            throw LaunchError.bundleIdentifierNotFound(url)
        }

        let wasAlreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty

        // Use native API for UIElement/Background modes or synchronous launches
        if configuration.mode != .foreground || configuration.synchronous {
            let options = buildLaunchOptions(for: configuration)
            return try launchNative(
                at: url,
                options: options as CFDictionary,
                configuration: configuration,
                bundleIdentifier: bundleIdentifier,
                startTime: startTime,
                wasAlreadyRunning: wasAlreadyRunning
            )
        }

        // Use NSWorkspace for standard foreground launches
        return try launchWithWorkspace(
            at: url,
            configuration: configuration,
            bundleIdentifier: bundleIdentifier,
            startTime: startTime,
            wasAlreadyRunning: wasAlreadyRunning
        )
    }

    // MARK: - Private Launch Helpers

    private func buildLaunchOptions(for configuration: LaunchConfiguration) -> [String: Any] {
        var options: [String: Any] = [:]

        switch configuration.mode {
        case .foreground:
            if let key = optionKeys["kLSOpenOptionForegroundLaunchKey"] {
                options[key as String] = true
            }
        case .uiElement:
            if let key = optionKeys["kLSOpenOptionUIElementLaunchKey"] {
                options[key as String] = true
            }
        case .backgroundOnly:
            if let key = optionKeys["kLSOpenOptionBackgroundLaunchKey"] {
                options[key as String] = true
            }
        }

        if configuration.synchronous, let key = optionKeys["kLSOpenOptionSynchronousKey"] {
            options[key as String] = true
        }

        if let key = optionKeys["kLSOpenOptionActivateKey"] {
            options[key as String] = configuration.activate
        }

        if configuration.hide, let key = optionKeys["kLSOpenOptionHideKey"] {
            options[key as String] = true
        }

        if let key = optionKeys["kLSOpenOptionPreferRunningInstanceKey"] {
            options[key as String] = configuration.preferRunningInstance ? 1 : 0
        }

        if let args = configuration.arguments, let key = optionKeys["kLSOpenOptionArgumentsKey"] {
            options[key as String] = args
        }

        if let env = configuration.environment, let key = optionKeys["kLSOpenOptionEnvironmentVariablesKey"] {
            options[key as String] = env
        }

        if !configuration.restoreState, let key = optionKeys["kLSOpenOptionLaunchWithoutRestoringStateKey"] {
            options[key as String] = true
        }

        return options
    }

    private func launchNative(
        at url: URL,
        options: CFDictionary,
        configuration: LaunchConfiguration,
        bundleIdentifier: String,
        startTime: Date,
        wasAlreadyRunning: Bool
    ) throws -> LaunchResult {
        _LSOpenURLsWithCompletionHandler([url] as CFArray, url as CFURL, options, nil)

        let timeout = configuration.launchTimeout

        while true {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                if configuration.synchronous {
                    let checkInStart = Date()
                    while !app.isFinishedLaunching {
                        if Date().timeIntervalSince(checkInStart) > configuration.checkInTimeout {
                            break
                        }
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                    }
                }

                return LaunchResult(
                    application: app,
                    launchDuration: Date().timeIntervalSince(startTime),
                    wasAlreadyRunning: wasAlreadyRunning,
                    isFinishedLaunching: app.isFinishedLaunching
                )
            }

            if Date().timeIntervalSince(startTime) > timeout {
                throw LaunchError.launchTimeout(timeout)
            }

            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func launchWithWorkspace(
        at url: URL,
        configuration: LaunchConfiguration,
        bundleIdentifier: String,
        startTime: Date,
        wasAlreadyRunning: Bool
    ) throws -> LaunchResult {
        let wsConfig = NSWorkspace.OpenConfiguration()
        wsConfig.activates = configuration.activate
        wsConfig.hides = configuration.hide
        wsConfig.arguments = configuration.arguments ?? []
        wsConfig.environment = configuration.environment ?? [:]

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resultApp: NSRunningApplication?
        nonisolated(unsafe) var resultError: Error?

        NSWorkspace.shared.openApplication(at: url, configuration: wsConfig) { app, error in
            resultApp = app
            resultError = error
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + configuration.launchTimeout)

        if waitResult == .timedOut {
            throw LaunchError.launchTimeout(configuration.launchTimeout)
        }

        if let error = resultError {
            throw LaunchError.launchFailed(underlying: error)
        }

        guard let app = resultApp else {
            throw LaunchError.unknownError
        }

        // Wait for app to finish launching if synchronous
        if configuration.synchronous && !app.isFinishedLaunching {
            let checkInStart = Date()
            while !app.isFinishedLaunching {
                if Date().timeIntervalSince(checkInStart) > configuration.checkInTimeout {
                    throw LaunchError.checkInTimeout(configuration.checkInTimeout)
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        return LaunchResult(
            application: app,
            launchDuration: Date().timeIntervalSince(startTime),
            wasAlreadyRunning: wasAlreadyRunning,
            isFinishedLaunching: app.isFinishedLaunching
        )
    }

    // MARK: - Open URLs with Specific Target

    /// Open URLs using a specific running application (by ASN)
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - targetASN: The ASN of the target running application
    ///   - activate: Whether to activate (bring to front) the target application
    ///   - preferRunningInstance: Whether to prefer the running instance
    public func openURLs(
        _ urls: [URL],
        targetASN: LSASN,
        activate: Bool = false,
        preferRunningInstance: Bool = true
    ) {
        var options: [String: Any] = [:]

        // Don't bring to front unless requested
        if let activateKey = optionKeys["kLSOpenOptionActivateKey"] {
            options[activateKey as String] = activate
        }

        // Don't promote to foreground
        if let fgKey = optionKeys["kLSOpenOptionForegroundLaunchKey"] {
            options[fgKey as String] = false
        }

        // Prefer the running instance we're targeting
        if let preferKey = optionKeys["kLSOpenOptionPreferRunningInstanceKey"] {
            options[preferKey as String] = preferRunningInstance ? 1 : 0
        }

        _LSOpenURLsUsingASNWithCompletionHandler(
            urls as CFArray,
            targetASN,
            options as CFDictionary,
            nil
        )
    }

    /// Open URLs using a specific running application (by NSRunningApplication)
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - app: The target running application
    ///   - activate: Whether to activate (bring to front) the target application
    public func openURLs(
        _ urls: [URL],
        in app: NSRunningApplication,
        activate: Bool = false
    ) throws {
        // Use bundle identifier approach - more reliable than ASN for scheme URLs
        guard let bundleID = app.bundleIdentifier else {
            throw LaunchError.asnCreationFailed(app.processIdentifier)
        }
        openURLs(urls, bundleIdentifier: bundleID, activate: activate)
    }

    /// Open URLs using a specific bundle identifier
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - bundleIdentifier: The bundle identifier of the target application
    ///   - activate: Whether to activate (bring to front) the target application
    ///   - preferRunningInstance: Whether to prefer a running instance over launching new
    public func openURLs(
        _ urls: [URL],
        bundleIdentifier: String,
        activate: Bool = false,
        preferRunningInstance: Bool = true
    ) {
        var options: [String: Any] = [:]

        if let activateKey = optionKeys["kLSOpenOptionActivateKey"] {
            options[activateKey as String] = activate
        }

        // Only set foreground launch key if we don't want activation
        // Setting this to false can interfere with URL handling
        if !activate, let fgKey = optionKeys["kLSOpenOptionForegroundLaunchKey"] {
            options[fgKey as String] = false
        }

        if let preferKey = optionKeys["kLSOpenOptionPreferRunningInstanceKey"] {
            options[preferKey as String] = preferRunningInstance ? 1 : 0
        }

        _LSOpenURLsUsingBundleIdentifierWithCompletionHandler(
            urls as CFArray,
            bundleIdentifier as CFString,
            options as CFDictionary,
            nil
        )
    }

    // MARK: - Direct Apple Event URL Sending

    /// Send a URL directly to a specific running application via Apple Events.
    /// This bypasses LaunchServices' URL scheme handler resolution and sends
    /// the GetURL (GURL) event directly to the target process.
    /// - Parameters:
    ///   - url: The URL to send
    ///   - app: The target running application
    /// - Returns: OSStatus indicating success (noErr) or failure
    @discardableResult
    public func sendURL(_ url: URL, to app: NSRunningApplication) -> OSStatus {
        return sendURLViaAppleEvent(url.absoluteString, toProcessID: app.processIdentifier)
    }

    /// Send a URL string directly to a specific process via Apple Events.
    /// - Parameters:
    ///   - urlString: The URL string to send
    ///   - pid: The process ID of the target application
    /// - Returns: OSStatus indicating success (noErr) or failure
    @discardableResult
    public func sendURLViaAppleEvent(_ urlString: String, toProcessID pid: pid_t) -> OSStatus {
        // Internet event class (GURL) and event ID
        let kInternetEventClass: AEEventClass = 0x4755524C  // 'GURL'
        let kAEGetURL: AEEventID = 0x4755524C               // 'GURL'

        // Create address descriptor targeting the specific process by PID
        var targetAddress = AEAddressDesc()
        var pidValue = pid
        var err = AECreateDesc(
            typeKernelProcessID,
            &pidValue,
            MemoryLayout<pid_t>.size,
            &targetAddress
        )
        guard err == noErr else {
            return OSStatus(err)
        }
        defer { AEDisposeDesc(&targetAddress) }

        // Create the Apple Event
        var event = AppleEvent()
        err = AECreateAppleEvent(
            kInternetEventClass,
            kAEGetURL,
            &targetAddress,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )
        guard err == noErr else {
            return OSStatus(err)
        }
        defer { AEDisposeDesc(&event) }

        // Add the URL as the direct parameter
        var urlDesc = AEDesc()
        let urlData = urlString.data(using: .utf8)!
        err = urlData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
            AECreateDesc(
                typeUTF8Text,
                bytes.baseAddress,
                urlData.count,
                &urlDesc
            )
        }
        guard err == noErr else {
            return OSStatus(err)
        }
        defer { AEDisposeDesc(&urlDesc) }

        err = AEPutParamDesc(&event, keyDirectObject, &urlDesc)
        guard err == noErr else {
            return OSStatus(err)
        }

        // Send the event (no reply needed)
        var reply = AppleEvent()
        let sendStatus = AESendMessage(
            &event,
            &reply,
            AESendMode(kAENoReply),
            kAEDefaultTimeout
        )
        AEDisposeDesc(&reply)

        return sendStatus
    }

    /// Lock an application to UIElement mode, preventing it from self-promoting to foreground
    /// This sets both the current type and the "restore" type to UIElement
    /// - Parameter app: The running application to lock
    /// - Throws: `LaunchError` if the ASN cannot be created
    public func lockToUIElement(_ app: NSRunningApplication) throws {
        guard let asn = getASN(for: app) else {
            throw LaunchError.asnCreationFailed(app.processIdentifier)
        }

        // Set current type to UIElement
        setApplicationInfo(asn: asn, key: kLSApplicationTypeKey, value: "UIElement" as CFString)

        // Set restore type to UIElement - this prevents apps from promoting themselves back
        setApplicationInfo(asn: asn, key: kLSApplicationTypeToRestoreKey, value: "UIElement" as CFString)
    }

    // MARK: - NSAppleEventDescriptor-based URL Sending

    /// Send a URL to an application using NSAppleEventDescriptor (higher-level API).
    /// This is an alternative to `sendURLViaAppleEvent` which uses the lower-level C API.
    ///
    /// - Parameters:
    ///   - urlString: The URL string to send
    ///   - pid: The process ID of the target application
    ///   - options: Send options (default: .neverInteract to avoid activation)
    ///   - timeout: Timeout in seconds (default: 30)
    /// - Throws: Error if the send fails
    public func sendURLViaNSAppleEventDescriptor(
        _ urlString: String,
        toProcessID pid: pid_t,
        options: NSAppleEventDescriptor.SendOptions = [.neverInteract],
        timeout: TimeInterval = 30
    ) throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        event.setParam(
            NSAppleEventDescriptor(string: urlString),
            forKeyword: AEKeyword(keyDirectObject)
        )

        // sendEvent returns the reply descriptor, or throws on error
        _ = try event.sendEvent(options: options, timeout: timeout)
    }

    /// Send a URL to an application using NSAppleEventDescriptor (async version).
    ///
    /// - Parameters:
    ///   - urlString: The URL string to send
    ///   - pid: The process ID of the target application
    ///   - options: Send options
    ///   - timeout: Timeout in seconds
    /// - Throws: Error if the send fails
    @available(macOS 10.15, *)
    public func sendURLViaNSAppleEventDescriptorAsync(
        _ urlString: String,
        toProcessID pid: pid_t,
        options: NSAppleEventDescriptor.SendOptions = [.neverInteract],
        timeout: TimeInterval = 30
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.sendURLViaNSAppleEventDescriptor(
                        urlString,
                        toProcessID: pid,
                        options: options,
                        timeout: timeout
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Async Deep Link Sending

    /// Method to use for sending deep links
    public enum DeepLinkSendMethod: String, CaseIterable, Sendable {
        case cAPI = "C API (AESendMessage)"
        case nsAppleEventDescriptor = "NSAppleEventDescriptor"
    }

    /// Result of sending a deep link, including diagnostic information
    public struct DeepLinkSendResult: Sendable {
        public let status: OSStatus
        public let targetPID: pid_t
        public let sendDurationMs: Double
        public let isFinishedLaunchingBefore: Bool
        public let isFinishedLaunchingAfter: Bool
        public let pidExistsAfter: Bool
        public let instanceCountBefore: Int
        public let instanceCountAfter: Int
        public let method: String
        public let error: String?

        public var success: Bool { status == noErr && error == nil }
        public var newInstanceSpawned: Bool { instanceCountAfter > instanceCountBefore }
    }

    /// Send a URL to an application asynchronously on a background thread.
    /// This prevents blocking the main thread and allows proper await semantics.
    ///
    /// - Parameters:
    ///   - urlString: The URL string to send
    ///   - app: The target running application
    ///   - bundleIdentifier: Bundle ID for monitoring instance count changes
    ///   - method: Which API to use for sending (default: C API)
    /// - Returns: DeepLinkSendResult with diagnostic information
    @available(macOS 10.15, *)
    public func sendURLAsync(
        _ urlString: String,
        to app: NSRunningApplication,
        bundleIdentifier: String,
        method: DeepLinkSendMethod = .cAPI
    ) async -> DeepLinkSendResult {
        let pid = app.processIdentifier

        // Capture state before sending
        let isFinishedLaunchingBefore = app.isFinishedLaunching
        let instanceCountBefore = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let startTime = CFAbsoluteTimeGetCurrent()

                var status: OSStatus = noErr
                var errorMessage: String? = nil

                // Send using the selected method
                switch method {
                case .cAPI:
                    status = sendURLViaAppleEvent(urlString, toProcessID: pid)

                case .nsAppleEventDescriptor:
                    do {
                        try sendURLViaNSAppleEventDescriptor(urlString, toProcessID: pid)
                    } catch {
                        status = OSStatus(errAEEventFailed)
                        errorMessage = error.localizedDescription
                    }
                }

                let endTime = CFAbsoluteTimeGetCurrent()
                let durationMs = (endTime - startTime) * 1000

                // Check state after sending
                let appStillExists = NSRunningApplication(processIdentifier: pid) != nil
                let isFinishedLaunchingAfter = app.isFinishedLaunching
                let instanceCountAfter = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count

                let result = DeepLinkSendResult(
                    status: status,
                    targetPID: pid,
                    sendDurationMs: durationMs,
                    isFinishedLaunchingBefore: isFinishedLaunchingBefore,
                    isFinishedLaunchingAfter: isFinishedLaunchingAfter,
                    pidExistsAfter: appStillExists,
                    instanceCountBefore: instanceCountBefore,
                    instanceCountAfter: instanceCountAfter,
                    method: method.rawValue,
                    error: errorMessage
                )

                continuation.resume(returning: result)
            }
        }
    }

    /// Send a URL to an application synchronously but with detailed monitoring.
    /// Returns diagnostic information about what happened during the send.
    ///
    /// - Parameters:
    ///   - urlString: The URL string to send
    ///   - app: The target running application
    ///   - bundleIdentifier: Bundle ID for monitoring instance count changes
    /// - Returns: DeepLinkSendResult with diagnostic information
    public func sendURLWithMonitoring(
        _ urlString: String,
        to app: NSRunningApplication,
        bundleIdentifier: String
    ) -> DeepLinkSendResult {
        let pid = app.processIdentifier

        // Capture state before sending
        let isFinishedLaunchingBefore = app.isFinishedLaunching
        let instanceCountBefore = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count

        let startTime = CFAbsoluteTimeGetCurrent()

        // Send the AppleEvent
        let status = sendURLViaAppleEvent(urlString, toProcessID: pid)

        let endTime = CFAbsoluteTimeGetCurrent()
        let durationMs = (endTime - startTime) * 1000

        // Check state after sending
        let appStillExists = NSRunningApplication(processIdentifier: pid) != nil
        let isFinishedLaunchingAfter = app.isFinishedLaunching
        let instanceCountAfter = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count

        return DeepLinkSendResult(
            status: status,
            targetPID: pid,
            sendDurationMs: durationMs,
            isFinishedLaunchingBefore: isFinishedLaunchingBefore,
            isFinishedLaunchingAfter: isFinishedLaunchingAfter,
            pidExistsAfter: appStillExists,
            instanceCountBefore: instanceCountBefore,
            instanceCountAfter: instanceCountAfter,
            method: DeepLinkSendMethod.cAPI.rawValue,
            error: nil
        )
    }

    // MARK: - Application Health Checks

    /// Check if an application is responsive by sending a null AppleEvent and waiting for a response.
    /// This is useful for detecting "zombie" applications that are running but not responding.
    ///
    /// - Parameters:
    ///   - pid: The process ID of the target application
    ///   - timeout: Timeout in seconds (default 2 seconds)
    /// - Returns: true if the application responds within the timeout, false otherwise
    public func isResponsive(pid: pid_t, timeout: TimeInterval = 2.0) -> Bool {
        // Create address descriptor targeting the specific process by PID
        var targetAddress = AEAddressDesc()
        var pidValue = pid
        var err = AECreateDesc(
            typeKernelProcessID,
            &pidValue,
            MemoryLayout<pid_t>.size,
            &targetAddress
        )
        guard err == noErr else { return false }
        defer { AEDisposeDesc(&targetAddress) }

        // Create a null AppleEvent (kCoreEventClass / kAENull)
        // This is a simple "ping" that any app should respond to
        let kCoreEventClass: AEEventClass = 0x61657674  // 'aevt'
        let kAENull: AEEventID = 0x6E756C6C            // 'null'

        var event = AppleEvent()
        err = AECreateAppleEvent(
            kCoreEventClass,
            kAENull,
            &targetAddress,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )
        guard err == noErr else { return false }
        defer { AEDisposeDesc(&event) }

        // Send the event and wait for a reply with timeout
        var reply = AppleEvent()
        let timeoutTicks = Int(timeout * 60.0)  // Convert seconds to ticks (60 ticks per second)
        let sendStatus = AESendMessage(
            &event,
            &reply,
            AESendMode(kAEWaitReply),
            timeoutTicks
        )
        AEDisposeDesc(&reply)

        // If we get noErr or errAEEventNotHandled, the app is responsive
        // errAETimeout means the app didn't respond in time
        return sendStatus == noErr || sendStatus == OSErr(errAEEventNotHandled)
    }

    /// Check if a running application is responsive.
    /// - Parameters:
    ///   - app: The running application to check
    ///   - timeout: Timeout in seconds (default 2 seconds)
    /// - Returns: true if the application responds within the timeout, false otherwise
    public func isResponsive(_ app: NSRunningApplication, timeout: TimeInterval = 2.0) -> Bool {
        isResponsive(pid: app.processIdentifier, timeout: timeout)
    }

    /// Find all unresponsive (zombie) instances of an application.
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier to search for
    ///   - timeout: Timeout in seconds per instance (default 2 seconds)
    /// - Returns: Array of unresponsive running applications
    public func findZombieInstances(bundleIdentifier: String, timeout: TimeInterval = 2.0) -> [NSRunningApplication] {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return instances.filter { !isResponsive($0, timeout: timeout) }
    }

    /// Kill all unresponsive (zombie) instances of an application.
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier to search for
    ///   - timeout: Timeout in seconds per instance (default 2 seconds)
    ///   - force: If true, use forceTerminate() instead of terminate()
    /// - Returns: Number of instances killed
    @discardableResult
    public func killZombieInstances(bundleIdentifier: String, timeout: TimeInterval = 2.0, force: Bool = true) -> Int {
        let zombies = findZombieInstances(bundleIdentifier: bundleIdentifier, timeout: timeout)
        var killed = 0

        for app in zombies {
            let success = force ? app.forceTerminate() : app.terminate()
            if success {
                killed += 1
            }
        }

        return killed
    }

    // MARK: - Running Applications

    /// Get all running applications from LaunchServices
    public func copyRunningApplications(sessionID: Int32 = kLSDefaultSessionID) -> [LSASN]? {
        guard let array = _LSCopyRunningApplicationArray(sessionID) else { return nil }
        return (array as NSArray) as [AnyObject]
    }

    /// Get the frontmost application
    public func copyFrontApplication(sessionID: Int32 = kLSDefaultSessionID) -> LSASN? {
        return _LSCopyFrontApplication(sessionID)
    }
}

// MARK: - Async/Await Support

extension LSApplicationLauncher {

    /// Launch an application by bundle identifier (async)
    @available(macOS 10.15, *)
    public func launch(
        bundleIdentifier: String,
        configuration: LaunchConfiguration = .default
    ) async throws -> LaunchResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.launch(bundleIdentifier: bundleIdentifier, configuration: configuration)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Launch an application at a URL (async)
    @available(macOS 10.15, *)
    public func launch(
        at url: URL,
        configuration: LaunchConfiguration = .default
    ) async throws -> LaunchResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.launch(at: url, configuration: configuration)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
