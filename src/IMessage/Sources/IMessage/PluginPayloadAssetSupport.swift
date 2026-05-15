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
        return try object(from: unmanaged, selector: selector)
    }

    static func performObject(_ object: NSObject, selector: Selector) throws -> AnyObject {
        guard object.responds(to: selector) else {
            throw ErrorMessage("Private framework method is unavailable: \(NSStringFromSelector(selector))")
        }
        return try self.object(from: object.perform(selector), selector: selector)
    }

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

    private static func object(from unmanaged: Unmanaged<AnyObject>?, selector: Selector) throws -> NSObject {
        guard let unmanaged,
              let object = unmanaged.takeUnretainedValue() as? NSObject else {
            throw ErrorMessage("Private framework method returned nil: \(NSStringFromSelector(selector))")
        }
        return object
    }
}
