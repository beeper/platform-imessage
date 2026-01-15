import Foundation
import AppKit

// MARK: - LSTypeObserver

/// Observes LaunchServices application type changes via callback notifications.
/// Can optionally auto-suppress specific apps to UIElement mode.
///
/// ## Usage
/// ```swift
/// let observer = LSTypeObserver()
///
/// // Start observing type changes
/// observer.startObserving { bundleID, pid, oldType, newType in
///     print("\(bundleID ?? "Unknown") changed from \(oldType) to \(newType)")
/// }
///
/// // Auto-suppress an app whenever it tries to become foreground
/// observer.addAutoSuppress(bundleID: "com.apple.MobileSMS")
///
/// // Stop observing
/// observer.stopObserving()
/// ```
public final class LSTypeObserver {

    // MARK: - Types

    /// Handler called when an application's type changes
    public typealias TypeChangeHandler = (
        _ bundleID: String?,
        _ pid: pid_t,
        _ oldType: ApplicationMode?,
        _ newType: ApplicationMode?
    ) -> Void

    // MARK: - Properties

    private let launcher = LSApplicationLauncher.shared

    private var notificationID: UnsafeMutableRawPointer?
    private let notificationQueue = DispatchQueue(label: "com.ls.type-observer", qos: .userInteractive)

    private var typeChangeHandler: TypeChangeHandler?
    private var autoSuppressBundleIDs: Set<String> = []
    private var lastKnownTypes: [pid_t: ApplicationMode] = [:]
    private let lock = NSLock()

    /// Whether the observer is currently active
    public private(set) var isObserving = false

    // MARK: - Initialization

    public init() {}

    deinit {
        stopObserving()
    }

    // MARK: - Public API

    /// Start observing application type changes.
    /// - Parameter handler: Called whenever an app's type changes
    // FIXME: (@pmanot) - Handler is currently broken, sometimes does not return the right type or pid
    public func startObserving(handler: @escaping TypeChangeHandler) {
        guard !isObserving else { return }

        self.typeChangeHandler = handler

        let block: LSNotificationBlock = { [weak self] code, timestamp, info, asnPtr, sessionID, context in
            self?.handleNotification(code: code, asnPtr: asnPtr)
        }

        guard let notifID = launcher._LSScheduleNotificationOnQueueWithBlock(
            kLSDefaultSessionID,
            nil,
            notificationQueue,
            block
        ) else {
            fatalError("Failed to schedule notification")
        }

        self.notificationID = notifID

        // Filter for only type change notifications
        let codes: [LSNotificationCode] = [LSNotificationConstants.applicationTypeChanged]
        _ = codes.withUnsafeBufferPointer { codesPtr in
            launcher._LSModifyNotification(notifID, 1, codesPtr.baseAddress, 0, nil, nil, nil)
        }

        isObserving = true
    }

    /// Stop observing type changes.
    public func stopObserving() {
        guard isObserving, let notifID = notificationID else { return }
        launcher._LSUnscheduleNotificationFunction(notifID)
        notificationID = nil
        isObserving = false
    }

    /// Add a bundle ID to auto-suppress to UIElement whenever it changes type.
    /// - Parameter bundleID: The bundle identifier to auto-suppress
    public func addAutoSuppress(bundleID: String) {
        lock.lock()
        autoSuppressBundleIDs.insert(bundleID)
        lock.unlock()

        // Immediately suppress if already running
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            suppressToUIElement(app)
        }
    }

    /// Remove a bundle ID from auto-suppress list.
    /// - Parameter bundleID: The bundle identifier to remove
    public func removeAutoSuppress(bundleID: String) {
        lock.lock()
        autoSuppressBundleIDs.remove(bundleID)
        lock.unlock()
    }

    /// Get all bundle IDs currently being auto-suppressed
    public var autoSuppressedBundleIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return autoSuppressBundleIDs
    }

    /// Check if a bundle ID is being auto-suppressed
    public func isAutoSuppressing(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return autoSuppressBundleIDs.contains(bundleID)
    }

    // MARK: - Private Methods

    /// Suppress an application to UIElement mode
    @discardableResult
    private func suppressToUIElement(_ app: NSRunningApplication) -> Bool {
        // Use the existing setApplicationMode which correctly sets both
        // kLSApplicationTypeKey and kLSApplicationTypeToRestoreKey
        return launcher.setApplicationMode(for: app, to: .uiElement) == noErr
    }

    private func handleNotification(code: LSNotificationCode, asnPtr: UnsafeRawPointer?) {
        guard code == LSNotificationConstants.applicationTypeChanged else { return }

        var pid: pid_t = 0
        var newType: ApplicationMode?
        var bundleID: String?

        if let asnPtr = asnPtr {
            let asn = Unmanaged<CFTypeRef>.fromOpaque(asnPtr).takeUnretainedValue()

            // Get the new type
            if let app = findApp(forASN: asn) {
                pid = app.processIdentifier
                bundleID = app.bundleIdentifier
                newType = launcher.getApplicationMode(for: app)
            }
        }

        // Get old type and update tracking
        lock.lock()
        let oldType = lastKnownTypes[pid]
        if let newType = newType {
            lastKnownTypes[pid] = newType
        }
        let suppressBundleIDs = autoSuppressBundleIDs
        lock.unlock()

        // Auto-suppress: check all tracked apps and suppress any that aren't UIElement
        for targetBundleID in suppressBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first {
                let currentType = launcher.getApplicationMode(for: app)
                if currentType != .uiElement {
                    suppressToUIElement(app)
                }
            }
        }

        // Call handler on main queue
        DispatchQueue.main.async { [weak self] in
            self?.typeChangeHandler?(bundleID, pid, oldType, newType)
        }
    }

    private func findApp(forASN asn: LSASN) -> NSRunningApplication? {
        let targetASNValue = launcher.asnToUInt64(asn)
        for app in NSWorkspace.shared.runningApplications {
            if let appASN = launcher.createASN(pid: app.processIdentifier) {
                if launcher.asnToUInt64(appASN) == targetASNValue {
                    return app
                }
            }
        }
        return nil
    }
}
