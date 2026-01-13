import Foundation
import AppKit
import Darwin

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

    private let kLSApplicationTypeKey: CFString
    private let kLSApplicationTypeToRestoreKey: CFString
    private let kLSApplicationUIElementTypeKey: CFString

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
        guard let asn = getASN(for: app) else {
            throw LaunchError.asnCreationFailed(app.processIdentifier)
        }
        openURLs(urls, targetASN: asn, activate: activate)
    }

    /// Open URLs using a specific bundle identifier
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - bundleIdentifier: The bundle identifier of the target application
    ///   - activate: Whether to activate (bring to front) the target application
    public func openURLs(
        _ urls: [URL],
        bundleIdentifier: String,
        activate: Bool = false
    ) {
        var options: [String: Any] = [:]

        if let activateKey = optionKeys["kLSOpenOptionActivateKey"] {
            options[activateKey as String] = activate
        }

        if let fgKey = optionKeys["kLSOpenOptionForegroundLaunchKey"] {
            options[fgKey as String] = false
        }

        _LSOpenURLsUsingBundleIdentifierWithCompletionHandler(
            urls as CFArray,
            bundleIdentifier as CFString,
            options as CFDictionary,
            nil
        )
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
