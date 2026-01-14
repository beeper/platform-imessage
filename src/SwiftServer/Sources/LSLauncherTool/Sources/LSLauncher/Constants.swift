import Foundation

// MARK: - LaunchServices Session IDs

/// Default session ID for the current user session
public let kLSDefaultSessionID: Int32 = -2

/// Session ID representing any/all sessions
public let kLSAnySessionID: Int32 = -1

// MARK: - LaunchServices Private API Types

/// Application Serial Number - opaque reference to a running application
public typealias LSASN = CFTypeRef

// MARK: - Launch Flags (from research at 0x180bb3a70)

/// Launch flags for LSLaunchURLSpec
public struct LSLaunchFlags: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Don't switch to the launched app (flag 0x200)
    /// Sets LSLaunchDoNotBringFrontmost in launch modifiers
    public static let dontSwitch = LSLaunchFlags(rawValue: 0x200)

    /// Launch asynchronously
    public static let async = LSLaunchFlags(rawValue: 0x10000)

    /// Don't add to recents
    public static let dontAddToRecents = LSLaunchFlags(rawValue: 0x100)

    /// Start app fresh (no state restoration)
    public static let newInstance = LSLaunchFlags(rawValue: 0x800000)
}

// MARK: - Bring Forward Request Keys (from research)
// Priority order: Forced > CausedByUserIntent > Immediate > Standard > IfFrontReservationExists

public enum LSBringForwardKey {
    /// Highest priority - forces activation regardless of other settings
    /// Address: 0x180cb577b
    public static let forced = "LSBringForwardRequestForced"

    /// High priority - user explicitly requested activation
    /// Address: 0x180cb580c
    public static let causedByUserIntent = "LSBringForwardRequestCausedByUserIntent"

    /// Medium priority - immediate activation requested
    /// Address: 0x180cb5797
    public static let immediate = "LSBringForwardRequestImmediate"

    /// Normal priority - standard activation behavior
    /// Address: 0x180cb57b6
    public static let standardActivation = "LSBringForwardRequestStandardActivation"

    /// Conditional - only if front reservation exists
    /// Address: 0x180cb57de
    public static let ifFrontReservationExists = "LSBringForwardRequestIfFrontReservationExists"

    /// Schedule activation when another app exits
    /// Address: 0x180cb49ca
    public static let atNextApplicationExit = "LSBringForwardAtNextApplicationExit"

    /// Delay before activation (TimeInterval)
    /// Address: 0x180cb5852
    public static let delay = "LSBringForwardDelay"

    /// Target specific window ID
    /// Address: 0x180cb5866
    public static let windowID = "LSBringForwardWindowID"

    /// Prevent any window from being brought forward
    /// Address: 0x180cdfcc0
    public static let noWindows = "LSBringForwardNoWindows"
}

// MARK: - Launch Modifier Keys (from research)

public enum LSLaunchModifierKey {
    /// Prevents the app from becoming frontmost
    /// Address: 0x180cb457d
    public static let doNotBringFrontmost = "LSLaunchDoNotBringFrontmost"

    /// Prevents any windows from being brought forward
    public static let doNotBringAnyWindowsForward = "LSDoNotBringAnyWindowsForward"
}

// MARK: - Session Meta Information Keys (from research)

public enum LSMetaInfoKey {
    /// Session-level flag to disable ALL post-launch bring-forward requests
    /// Stored in shared memory at offset 0x60, bit 0x1
    /// Address: 0x180cb4a81
    public static let disableAllPostLaunchBringForwardRequests = "LSDisableAllPostLaunchBringForwardRequests"

    /// Front reservation exists flag (bit 0x1 at offset 0x74)
    public static let frontReservationExists = "LSFrontReservationExists"

    /// Next app to bring forward (ASN low part at offset 0x6c)
    public static let nextAppToBringForwardASNLow = "LSNextAppToBringForwardASNLow"

    /// Permitted front ASNs list
    public static let permittedFrontASNs = "LSPermittedFrontASNs"
}

// MARK: - FrontBoard Options Keys (from research at 0x180cd224c)

public enum LSFrontBoardOptionKey {
    /// Whether to activate the app (CFBoolean)
    public static let activate = "_kLSOpenOptionActivateKey"

    /// Launch as foreground app
    public static let foregroundLaunch = "_kLSOpenOptionForegroundLaunchKey"

    /// Launch as UIElement (no dock icon, can have UI)
    public static let uiElementLaunch = "_kLSOpenOptionUIElementLaunchKey"

    /// Launch as background only (no dock, no UI)
    public static let backgroundLaunch = "_kLSOpenOptionBackgroundLaunchKey"

    /// Launch hidden
    public static let hide = "_kLSOpenOptionHideKey"

    /// Whether launch is a user action
    public static let launchIsUserAction = "_kLSOpenOptionLaunchIsUserActionKey"
}

// MARK: - Launch Roles (from research)

public enum LSLaunchRole: String {
    /// Full interactive, can become frontmost
    case userInteractiveFocal = "LaunchRoleUserInteractiveFocal"

    /// Interactive but won't become frontmost automatically
    case userInteractiveNonFocal = "LaunchRoleUserInteractiveNonFocal"

    /// Background process
    case background = "LaunchRoleBackground"

    /// Alias for background
    case nonUserInteractive = "LaunchRoleNonUserInteractive"
}

// MARK: - XPC Message Codes (for reference)

public enum LSXPCMessageCode {
    /// Copy launch modifiers
    public static let copyLaunchModifiers: UInt32 = 0x172

    /// Post launch modifiers
    public static let postLaunchModifiers: UInt32 = 0x17c

    /// Set application information item
    public static let setApplicationInformationItem: UInt32 = 0x1fe

    /// Set front application
    public static let setFrontApplication: UInt32 = 0x38e
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
