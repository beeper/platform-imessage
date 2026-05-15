import Foundation
import IMessageCore

private enum PerformArgumentCount {
    static let none = 0
    static let one = 1
    static let two = 2
}

enum PluginPayloadAssetSupport {
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
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: renderedURL, to: destinationURL)
    }

    @MainActor
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

    @MainActor
    static func performObject(_ object: NSObject, selector: Selector) throws -> AnyObject {
        try self.object(from: object.perform(selector), selector: selector)
    }

    @MainActor
    private static func object(from unmanaged: Unmanaged<AnyObject>?, selector: Selector) throws -> NSObject {
        guard let unmanaged,
              let object = unmanaged.takeUnretainedValue() as? NSObject else {
            throw ErrorMessage("Private framework method returned nil: \(NSStringFromSelector(selector))")
        }
        return object
    }
}
