import Darwin
import Foundation
import IMessageCore

private let pluginPayloadAssetRenderQueue = DispatchQueue(
    label: "plugin-payload-asset-render-queue",
    qos: .utility
)

private enum PerformArgumentCount {
    static let none = 0
    static let one = 1
    static let two = 2
}

enum PluginPayloadAssetSupport {
    static func onRenderQueue<T>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            pluginPayloadAssetRenderQueue.async {
                continuation.resume(with: Result {
                    try autoreleasepool {
                        try action()
                    }
                })
            }
        }
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func copyRenderedAsset(from renderedURL: URL, to destinationURL: URL, assetDescription: String) throws {
        guard fileSize(renderedURL) > 0 else {
            throw ErrorMessage("\(assetDescription) renderer produced an empty asset")
        }
        guard renderedURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            return
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: renderedURL, to: stagingURL)
        do {
            try atomicallyReplaceItem(at: destinationURL, with: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    static func initObject(
        _ cls: AnyClass,
        selector: Selector,
        _ args: Any?...
    ) throws -> NSObject {
        for arg in args {
            try rejectPrimitiveArgument(arg, selector: selector)
        }

        guard let allocated = cls.alloc() as? NSObject else {
            throw ErrorMessage("Couldn't allocate \(NSStringFromClass(cls))")
        }

        let unmanaged: Unmanaged<AnyObject>?
        switch args.count {
        case PerformArgumentCount.none:
            unmanaged = allocated.perform(selector)
        case PerformArgumentCount.one:
            unmanaged = allocated.perform(selector, with: args[0])
        case PerformArgumentCount.two:
            unmanaged = allocated.perform(selector, with: args[0], with: args[1])
        default:
            throw ErrorMessage("Unsupported private initializer arity")
        }
        // `init`-family selectors return a +1 retained reference, so consume the retain.
        return try object(from: unmanaged, selector: selector, consumesUnbalancedRetain: true)
    }

    /// Allocates `cls` and invokes a `(id, BOOL)` initializer via a typed IMP so the
    /// `BOOL` argument is forwarded as a primitive. Required because
    /// `NSObject.perform(_:with:with:)` only carries object pointers, so passing a Swift
    /// `Bool` would arrive as a non-zero `NSNumber` pointer and always read as `true`.
    static func initObject(
        _ cls: AnyClass,
        selector: Selector,
        withObject object: AnyObject,
        andFlag flag: Bool
    ) throws -> NSObject {
        guard let initMethod = class_getInstanceMethod(cls, selector) else {
            throw ErrorMessage(
                "Initializer is unavailable: \(NSStringFromClass(cls)) \(NSStringFromSelector(selector))"
            )
        }
        guard let allocated = cls.alloc() as? NSObject else {
            throw ErrorMessage("Couldn't allocate \(NSStringFromClass(cls))")
        }

        typealias ObjectAndBoolInitIMP = @convention(c) (NSObject, Selector, AnyObject, Bool) -> Unmanaged<AnyObject>?
        let initIMP = unsafeBitCast(method_getImplementation(initMethod), to: ObjectAndBoolInitIMP.self)
        let unmanaged = initIMP(allocated, selector, object, flag)
        // `init`-family selectors return a +1 retained reference, so consume the retain.
        return try self.object(from: unmanaged, selector: selector, consumesUnbalancedRetain: true)
    }

    static func performObject(_ object: NSObject, selector: Selector) throws -> AnyObject {
        guard object.responds(to: selector) else {
            throw ErrorMessage("Private framework method is unavailable: \(NSStringFromSelector(selector))")
        }
        // Non-init selectors follow Cocoa's +0 autoreleased return convention.
        return try self.object(from: object.perform(selector), selector: selector, consumesUnbalancedRetain: false)
    }

    /// Rejects Swift numeric/Bool values passed where the receiver expects a primitive
    /// `BOOL`/`int`/etc. argument. `NSObject.perform(_:with:...)` only carries object
    /// pointers, so a Swift `Bool` gets boxed into an `NSNumber` and the receiver reads
    /// the (always non-zero) pointer as a primitive — silently corrupting the value.
    private static func rejectPrimitiveArgument(_ value: Any?, selector: Selector) throws {
        guard let value else { return }
        let typeName = String(describing: type(of: value))
        if rejectedPrimitiveSwiftTypeNames.contains(typeName) {
            throw ErrorMessage(
                "initObject(_:selector:_:) only supports object arguments; got Swift primitive \(typeName) for \(NSStringFromSelector(selector)). Use initObject(_:selector:withObject:andFlag:) or wrap in NSNumber."
            )
        }
    }

    private static let rejectedPrimitiveSwiftTypeNames: Set<String> = [
        "Bool",
        "Int", "UInt",
        "Int8", "UInt8",
        "Int16", "UInt16",
        "Int32", "UInt32",
        "Int64", "UInt64",
        "Float", "Double",
    ]

    private static func atomicallyReplaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    return EINVAL
                }
                return rename(sourcePath, destinationPath) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    /// Unwraps the result of an Obj-C runtime `perform`/IMP call.
    ///
    /// `consumesUnbalancedRetain` selects between Cocoa's two return conventions:
    /// * `true` for `init`/`copy`/`mutableCopy`/`new`/`alloc`-family selectors, which
    ///   return a +1 retained reference that the caller owns. We use
    ///   `takeRetainedValue()` so ARC balances the +1 instead of leaking the object.
    /// * `false` for ordinary methods, which return autoreleased (+0) references —
    ///   `takeUnretainedValue()` is correct so we don't over-release.
    private static func object(
        from unmanaged: Unmanaged<AnyObject>?,
        selector: Selector,
        consumesUnbalancedRetain: Bool
    ) throws -> NSObject {
        guard let unmanaged else {
            throw ErrorMessage("Private framework method returned nil: \(NSStringFromSelector(selector))")
        }
        let value: AnyObject = consumesUnbalancedRetain
            ? unmanaged.takeRetainedValue()
            : unmanaged.takeUnretainedValue()
        guard let object = value as? NSObject else {
            throw ErrorMessage("Private framework method returned wrong type: \(NSStringFromSelector(selector))")
        }
        return object
    }
}
