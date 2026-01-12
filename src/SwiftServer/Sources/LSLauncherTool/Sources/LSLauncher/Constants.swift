import Foundation

// MARK: - LaunchServices Session IDs

/// Default session ID for the current user session
public let kLSDefaultSessionID: Int32 = -2

/// Session ID representing any/all sessions
public let kLSAnySessionID: Int32 = -1

// MARK: - LaunchServices Private API Types

/// Application Serial Number - opaque reference to a running application
public typealias LSASN = CFTypeRef

// MARK: - Private Function Types

typealias LSASNCreateWithPidFn = @convention(c) (CFAllocator?, pid_t) -> LSASN?
typealias LSASNToUInt64Fn = @convention(c) (LSASN) -> UInt64
typealias LSCopyApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString) -> CFTypeRef?
typealias LSSetApplicationInformationItemFn = @convention(c) (Int32, LSASN, CFString, CFTypeRef?, UnsafeMutablePointer<CFTypeRef?>?) -> Int32
typealias LSCopyRunningApplicationArrayFn = @convention(c) (Int32) -> CFArray?
typealias LSCopyFrontApplicationFn = @convention(c) (Int32) -> LSASN?
typealias LSOpenURLsWithCompletionHandlerFn = @convention(c) (CFArray?, CFURL?, CFDictionary?, UnsafeRawPointer?) -> Void
