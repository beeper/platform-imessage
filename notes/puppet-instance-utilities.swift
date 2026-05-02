// Scratch extraction from branch `purav/puppet-instance`.
//
// This file is intentionally outside `src/IMessage/Sources` so it is not
// compiled yet. It distills the older branch down to the utilities that look
// directly useful for adding a IMessage "secondary Messages instance" mode:
//
// - launch a fresh Messages.app instance with LaunchServices private options
// - target an existing NSRunningApplication with an imessage:// deep link
// - optionally hide/suppress the secondary instance from Dock/app switcher
//
// Source files consulted:
// - src/IMessage/Sources/LSLauncherTool/Sources/LSLauncher/OpenConfiguration+Private.swift
// - src/IMessage/Sources/LSLauncherTool/Sources/LSLauncher/LSApplicationLauncher.swift
// - src/IMessage/Sources/LSLauncherTool/Sources/LSLauncher/LaunchConfiguration.swift
// - src/IMessage/Sources/LSLauncherTool/Sources/LSLauncher/RunningApplication+Extensions.swift
// - src/IMessage/Sources/IMessage/Messages/MessagesApplication.swift

import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Private LaunchServices OpenConfiguration Options

extension NSWorkspace.OpenConfiguration {
    enum PuppetLSOption {
        static let getAdditionalOptions = Selector(("_additionalLSOpenOptions"))
        static let setAdditionalOptions = Selector(("_setAdditionalLSOpenOptions:"))

        static let activate = "_kLSOpenOptionActivateKey"
        static let addToRecents = "_kLSOpenOptionAddToRecentsKey"
        static let backgroundLaunch = "_kLSOpenOptionBackgroundLaunchKey"
        static let foregroundLaunch = "_kLSOpenOptionForegroundLaunchKey"
        static let hide = "_kLSOpenOptionHideKey"
        static let launchIsUserAction = "_kLSOpenOptionLaunchIsUserActionKey"
        static let launchWithoutRestoringState = "_kLSOpenOptionLaunchWithoutRestoringStateKey"
        static let preferRunningInstance = "_kLSOpenOptionPreferRunningInstanceKey"
        static let synchronous = "_kLSOpenOptionSynchronousKey"
        static let uiElementLaunch = "_kLSOpenOptionUIElementLaunchKey"
        static let waitForApplicationToCheckIn = "_kLSOpenOptionWaitForApplicationToCheckInKey"
    }

    private var puppetAdditionalOptions: [String: Any] {
        get {
            guard responds(to: PuppetLSOption.getAdditionalOptions),
                  let result = perform(PuppetLSOption.getAdditionalOptions)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                return [:]
            }
            return result
        }
        set {
            guard responds(to: PuppetLSOption.setAdditionalOptions) else { return }
            perform(PuppetLSOption.setAdditionalOptions, with: newValue)
        }
    }

    private func setPuppetBoolOption(_ value: Bool?, forKey key: String) {
        var options = puppetAdditionalOptions
        if let value {
            options[key] = value
        } else {
            options.removeValue(forKey: key)
        }
        puppetAdditionalOptions = options
    }

    var puppetLaunchesInBackground: Bool? {
        get { puppetAdditionalOptions[PuppetLSOption.backgroundLaunch] as? Bool }
        set { setPuppetBoolOption(newValue, forKey: PuppetLSOption.backgroundLaunch) }
    }

    var puppetLaunchIsUserAction: Bool? {
        get { puppetAdditionalOptions[PuppetLSOption.launchIsUserAction] as? Bool }
        set { setPuppetBoolOption(newValue, forKey: PuppetLSOption.launchIsUserAction) }
    }

    var puppetPreferRunningInstance: Bool? {
        get { puppetAdditionalOptions[PuppetLSOption.preferRunningInstance] as? Bool }
        set { setPuppetBoolOption(newValue, forKey: PuppetLSOption.preferRunningInstance) }
    }

    var puppetLaunchWithoutRestoringState: Bool? {
        get { puppetAdditionalOptions[PuppetLSOption.launchWithoutRestoringState] as? Bool }
        set { setPuppetBoolOption(newValue, forKey: PuppetLSOption.launchWithoutRestoringState) }
    }

    var puppetWaitForApplicationToCheckIn: Bool? {
        get { puppetAdditionalOptions[PuppetLSOption.waitForApplicationToCheckIn] as? Bool }
        set { setPuppetBoolOption(newValue, forKey: PuppetLSOption.waitForApplicationToCheckIn) }
    }
}

// MARK: - Targeted Messages Deep Links

enum PuppetMessagesInstanceUtilities {
    static let messagesBundleID = "com.apple.MobileSMS"

    enum Error: Swift.Error, CustomStringConvertible {
        case messagesApplicationURLNotFound
        case launchReturnedNoApplication
        case appleEventSendFailed(OSStatus)
        case launchTimedOut(TimeInterval)

        var description: String {
            switch self {
            case .messagesApplicationURLNotFound:
                return "Could not find /System/Applications/Messages.app via LaunchServices"
            case .launchReturnedNoApplication:
                return "LaunchServices completed without returning an NSRunningApplication"
            case let .appleEventSendFailed(status):
                return "Targeted deep link AppleEvent failed with OSStatus \(status)"
            case let .launchTimedOut(timeout):
                return "Timed out waiting for Messages.app launch after \(timeout)s"
            }
        }
    }

    /// Builds the AppleEvent that Messages handles for URL opens.
    ///
    /// With `target == nil`, this event can be attached to an
    /// `NSWorkspace.OpenConfiguration.appleEvent` while launching a fresh
    /// instance. With a target app, it sends the imessage:// URL to that exact
    /// PID and bypasses normal URL-handler routing.
    static func getURLAppleEvent(
        for url: URL,
        target: NSRunningApplication?
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target.map { NSAppleEventDescriptor(processIdentifier: $0.processIdentifier) },
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        event.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )

        return event
    }

    /// Sends an imessage:// deep link to one specific Messages.app process.
    static func sendDeepLink(
        _ url: URL,
        to app: NSRunningApplication,
        timeout: TimeInterval = 5
    ) throws {
        try getURLAppleEvent(for: url, target: app)
            .sendEvent(options: [.neverInteract, .noReply], timeout: timeout)
    }

    /// Lower-level C AppleEvent variant from the old LSLauncher tool.
    ///
    /// The NSAppleEventDescriptor version above is easier to integrate in
    /// IMessage. This version is useful if diagnostics show descriptor sends
    /// are flaky or need no-reply behavior without throwing.
    @discardableResult
    static func sendDeepLinkWithCAPI(
        _ url: URL,
        toProcessID pid: pid_t
    ) -> OSStatus {
        var targetAddress = AEAddressDesc()
        var pidValue = pid
        var err = AECreateDesc(
            typeKernelProcessID,
            &pidValue,
            MemoryLayout<pid_t>.size,
            &targetAddress
        )
        guard err == noErr else { return OSStatus(err) }
        defer { AEDisposeDesc(&targetAddress) }

        var event = AppleEvent()
        err = AECreateAppleEvent(
            AEEventClass(kInternetEventClass),
            AEEventID(kAEGetURL),
            &targetAddress,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )
        guard err == noErr else { return OSStatus(err) }
        defer { AEDisposeDesc(&event) }

        var urlDesc = AEDesc()
        let data = url.absoluteString.data(using: .utf8)!
        err = data.withUnsafeBytes { bytes in
            AECreateDesc(typeUTF8Text, bytes.baseAddress, data.count, &urlDesc)
        }
        guard err == noErr else { return OSStatus(err) }
        defer { AEDisposeDesc(&urlDesc) }

        err = AEPutParamDesc(&event, keyDirectObject, &urlDesc)
        guard err == noErr else { return OSStatus(err) }

        var reply = AppleEvent()
        let status = AESendMessage(&event, &reply, AESendMode(kAENoReply), kAEDefaultTimeout)
        AEDisposeDesc(&reply)
        return status
    }

    /// Launches a separate Messages.app process.
    ///
    /// Key behavior from the old branch:
    /// - `createsNewApplicationInstance = true` is the public replacement for
    ///   `kLSLaunchNewInstance` / `open -n`.
    /// - `allowsRunningApplicationSubstitution = false` prevents LaunchServices
    ///   from silently returning an existing instance.
    /// - `appleEvent` carries the first deeplink into the fresh instance.
    /// - private `puppetLaunchesInBackground` and `puppetLaunchIsUserAction`
    ///   mirror the old private LaunchServices flags.
    @MainActor
    static func launchSecondaryMessagesInstance(
        initialDeepLink: URL? = nil,
        activate: Bool = false,
        hide: Bool = true,
        launchInBackground: Bool = true,
        restoreState: Bool = false,
        timeout: TimeInterval = 8
    ) async throws -> NSRunningApplication {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) else {
            throw Error.messagesApplicationURLNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.hides = hide
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.puppetLaunchesInBackground = launchInBackground
        configuration.puppetLaunchIsUserAction = true
        configuration.puppetPreferRunningInstance = false
        configuration.puppetLaunchWithoutRestoringState = !restoreState
        configuration.puppetWaitForApplicationToCheckIn = true

        if let initialDeepLink {
            configuration.appleEvent = getURLAppleEvent(for: initialDeepLink, target: nil)
        }

        let app = try await NSWorkspace.shared.open(applicationURL, configuration: configuration)
        try await waitForLaunch(app, timeout: timeout)

        if hide {
            app.hide()
        }

        return app
    }

    static func waitForLaunch(
        _ app: NSRunningApplication,
        interval: TimeInterval = 0.05,
        timeout: TimeInterval = 8
    ) async throws {
        let start = Date()
        while !app.isFinishedLaunching {
            if app.isTerminated {
                throw Error.launchReturnedNoApplication
            }
            if Date().timeIntervalSince(start) > timeout {
                throw Error.launchTimedOut(timeout)
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

// MARK: - Optional LaunchServices App-Mode Suppression

enum PuppetApplicationMode: String {
    case foreground = "Foreground"
    case uiElement = "UIElement"
    case backgroundOnly = "BackgroundOnly"
}

/// Minimal subset of the old `LSApplicationLauncher`.
///
/// Useful if the secondary Messages instance should be hidden from Dock/app
/// switcher after launch. This uses private LaunchServices symbols, so keep it
/// behind an explicit feature flag and fail soft.
final class PuppetLSApplicationModeController {
    typealias LSASN = CFTypeRef
    typealias LSASNCreateWithPidFn = @convention(c) (CFAllocator?, pid_t) -> LSASN?
    typealias LSCopyApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString) -> CFTypeRef?
    typealias LSSetApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString, CFTypeRef?, UnsafeMutablePointer<CFTypeRef?>?) -> Int32

    static let shared = PuppetLSApplicationModeController()
    private static let defaultSessionID: Int32 = -2

    private let handle: UnsafeMutableRawPointer?
    private let bundle: CFBundle?
    private let createASNWithPid: LSASNCreateWithPidFn?
    private let copyApplicationInformationItem: LSCopyApplicationInformationItemFn?
    private let setApplicationInformationItem: LSSetApplicationInformationItemFn?
    private let applicationTypeKey: CFString?
    private let applicationTypeToRestoreKey: CFString?
    private let applicationUIElementTypeKey: CFString?

    private init() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices"
        handle = dlopen(path, RTLD_NOW)
        bundle = CFBundleGetBundleWithIdentifier("com.apple.LaunchServices" as CFString)
            ?? CFBundleCreate(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL)

        func loadFunction<T>(_ name: String) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        createASNWithPid = loadFunction("_LSASNCreateWithPid")
        copyApplicationInformationItem = loadFunction("_LSCopyApplicationInformationItem")
        setApplicationInformationItem = loadFunction("_LSSetApplicationInformationItem")

        applicationTypeKey = Self.loadCFString(bundle: bundle, named: "kLSApplicationTypeKey")
        applicationTypeToRestoreKey = Self.loadCFString(bundle: bundle, named: "kLSApplicationTypeToRestoreKey")
        applicationUIElementTypeKey = Self.loadCFString(bundle: bundle, named: "kLSApplicationUIElementTypeKey")
    }

    private static func loadCFString(bundle: CFBundle?, named name: String) -> CFString? {
        guard let bundle else { return nil }
        for symbol in ["_\(name)", name] {
            guard let raw = CFBundleGetDataPointerForName(bundle, symbol as CFString) else {
                continue
            }
            let pointer = raw.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
            guard let pointer else { continue }
            return unsafeBitCast(pointer, to: CFString.self)
        }
        return nil
    }

    func mode(for app: NSRunningApplication) -> PuppetApplicationMode? {
        guard let asn = createASNWithPid?(nil, app.processIdentifier),
              let applicationTypeKey,
              let value = copyApplicationInformationItem?(Self.defaultSessionID, asn, applicationTypeKey) as? String
        else {
            return nil
        }
        return PuppetApplicationMode(rawValue: value)
    }

    @discardableResult
    func setMode(
        _ mode: PuppetApplicationMode,
        for app: NSRunningApplication
    ) -> OSStatus {
        guard let asn = createASNWithPid?(nil, app.processIdentifier),
              let setApplicationInformationItem,
              let applicationTypeKey,
              let applicationTypeToRestoreKey
        else {
            return OSStatus(kLSApplicationNotFoundErr)
        }

        let value: CFString
        switch mode {
        case .foreground:
            value = "Foreground" as CFString
        case .uiElement:
            value = applicationUIElementTypeKey ?? "UIElement" as CFString
        case .backgroundOnly:
            value = "BackgroundOnly" as CFString
        }

        let restoreStatus = setApplicationInformationItem(
            Self.defaultSessionID,
            asn,
            applicationTypeToRestoreKey,
            value,
            nil
        )
        let currentStatus = setApplicationInformationItem(
            Self.defaultSessionID,
            asn,
            applicationTypeKey,
            value,
            nil
        )

        return restoreStatus != noErr ? OSStatus(restoreStatus) : OSStatus(currentStatus)
    }

    func suppressToUIElement(_ app: NSRunningApplication) throws {
        let status = setMode(.uiElement, for: app)
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

extension NSRunningApplication {
    var puppetApplicationMode: PuppetApplicationMode? {
        PuppetLSApplicationModeController.shared.mode(for: self)
    }

    func suppressPuppetInstanceToUIElement() throws {
        try PuppetLSApplicationModeController.shared.suppressToUIElement(self)
    }
}
