import Foundation

// MARK: - LaunchServices Session IDs

/// Default session ID for the current user session
public let kLSDefaultSessionID: Int32 = -2

/// Session ID representing any/all sessions
public let kLSAnySessionID: Int32 = -1

// MARK: - LaunchServices Private API Types

/// Application Serial Number - opaque reference to a running application
public typealias LSASN = CFTypeRef

/// Notification code type for LaunchServices notifications
public typealias LSNotificationCode = Int32

/// Session ID type alias
public typealias LSSessionID = Int32

// MARK: - Notification Constants

public enum LSNotificationConstants {
    /// Notification code for application type changes (e.g., Foreground -> UIElement)
    public static let applicationTypeChanged: LSNotificationCode = 0x231
}

// MARK: - Private Function Types

typealias LSASNCreateWithPidFn = @convention(c) (CFAllocator?, pid_t) -> LSASN?
typealias LSASNToUInt64Fn = @convention(c) (LSASN) -> UInt64
typealias LSCopyApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString) -> CFTypeRef?
typealias LSSetApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString, CFTypeRef?, UnsafeMutablePointer<CFTypeRef?>?) -> Int32
typealias LSCopyRunningApplicationArrayFn = @convention(c) (Int32) -> CFArray?
typealias LSCopyFrontApplicationFn = @convention(c) (Int32) -> LSASN?
typealias LSOpenURLsWithCompletionHandlerFn = @convention(c) (CFArray?, CFURL?, CFDictionary?, UnsafeRawPointer?) -> Void

// Open URLs targeting a specific ASN (running application)
typealias LSOpenURLsUsingASNWithCompletionHandlerFn = @convention(c) (
    CFArray?,      // URLs to open
    CFTypeRef,     // Target ASN
    CFDictionary?, // Options dictionary
    UnsafeRawPointer? // Completion handler (nullable)
) -> Void

// Open URLs targeting a specific bundle identifier
typealias LSOpenURLsUsingBundleIdentifierWithCompletionHandlerFn = @convention(c) (
    CFArray?,      // URLs to open
    CFString,      // Bundle identifier
    CFDictionary?, // Options dictionary
    UnsafeRawPointer? // Completion handler
) -> Void

// MARK: - Notification Function Types

/// Block type for LaunchServices notifications
public typealias LSNotificationBlock = @convention(block) (
    LSNotificationCode,    // Notification code
    Double,                // Timestamp
    UnsafeRawPointer?,     // Info
    UnsafeRawPointer?,     // ASN pointer
    LSSessionID,           // Session ID
    UnsafeRawPointer?      // Context
) -> Void

/// Schedule a notification callback on a dispatch queue
typealias LSScheduleNotificationOnQueueWithBlockFn = @convention(c) (
    LSSessionID,           // Session ID
    LSASN?,                // Optional ASN to filter for
    DispatchQueue?,        // Queue to receive notifications on
    @escaping LSNotificationBlock  // Callback block
) -> UnsafeMutableRawPointer?  // Returns notification ID

/// Modify notification subscription (add/remove notification codes)
typealias LSModifyNotificationFn = @convention(c) (
    UnsafeMutableRawPointer,       // Notification ID
    Int,                           // Number of codes to add
    UnsafePointer<LSNotificationCode>?,  // Codes to add
    Int,                           // Number of codes to remove
    UnsafePointer<LSNotificationCode>?,  // Codes to remove
    CFArray?,                      // Unknown
    CFArray?                       // Unknown
) -> Int32

/// Unschedule/cancel a notification subscription
typealias LSUnscheduleNotificationFunctionFn = @convention(c) (
    UnsafeMutableRawPointer  // Notification ID
) -> Void
