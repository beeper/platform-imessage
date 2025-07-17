import SwiftServerFoundation
import ExceptionCatcher
import Foundation

// for window title prediction, the phone number is formatted nicely, e.g.
//
// "+902302251169" => "+90 (230) 225 11 69"
// "+17075551234" => "+1 (707) 555-1234"
//
// i haven't verified this is 100% used in the window title, but it seems to
// receive heavy usage according to binary ninja's x-refs, and lines up with
// my chats

// there is also `IMFormatPhoneNumber(String, includeCountryCode: Bool)` but
// that appears to be doing some kind of normalization? (also, param name is
// a guess)

// TODO: a more generalized SPI/"soft-linking" framework

enum SPIError: Error, CustomStringConvertible {
    case imageNotFound
    case functionNotFound
    case dynamicLinking(String)

    static var current: Self? {
        guard let errorMessage = dlerror() else {
            return nil
        }
        return .dynamicLinking(String(cString: errorMessage))
    }

    var description: String {
        switch self {
        case .imageNotFound: "dlopen failed"
        case .functionNotFound: "dlsym failed"
        case let .dynamicLinking(message): "dlerror: \(message)"
        }
    }
}

// this might not actually return `nil`, but just in case
typealias IMFormattedDisplayStringForNumberFunction = (@convention(c) (String, Locale) -> String?)
private var functionPointerCacheLock = UnfairLock()
private var functionPointerCache: IMFormattedDisplayStringForNumberFunction?

private func formattedDisplayStringFunction() throws -> IMFormattedDisplayStringForNumberFunction {
    functionPointerCacheLock.lock()
    defer { functionPointerCacheLock.unlock() }

    if let functionPointerCache {
        return functionPointerCache
    }

    guard let imCore = dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW) else {
        throw SPIError.current ?? .imageNotFound
    }

    guard let pointer = unsafeBitCast(
        dlsym(imCore, "IMFormattedDisplayStringForNumber"),
        to: (@convention(c) (String, Locale) -> String?)?.self
    ) else {
        throw SPIError.current ?? .functionNotFound
    }

    functionPointerCache = pointer
    return pointer
}

func formattedDisplayString(phoneNumber: String) throws -> String? {
    guard Defaults.swiftServer.bool(forKey: DefaultsKeys.imCoreSPI) else {
        return nil
    }

    let function = try formattedDisplayStringFunction()
    // just in case
    return try ExceptionCatcher.catch {
        function(phoneNumber, .autoupdatingCurrent)
    }
}
