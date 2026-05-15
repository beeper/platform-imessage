import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import ObjectiveC

private let digitalTouchBalloonProviderPath = "/System/Library/Messages/iMessageBalloons/DigitalTouchBalloonProvider.bundle"
private let digitalTouchBalloonProviderBundleID = "com.apple.DigitalTouchBalloonProvider"

enum DigitalTouchAssetRenderer {
    static func render(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) async throws -> URL {
        try await MainActor.run {
            try ExceptionCatcher.catch {
                try renderOnMainThread(payloadData: payloadData, uuid: uuid, isFromMe: isFromMe, destinationURL: destinationURL)
            }
        }
    }

    @MainActor
    private static func renderOnMainThread(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) throws -> URL {
        guard Bundle(path: digitalTouchBalloonProviderPath)?.load() == true else {
            throw ErrorMessage("Couldn't load DigitalTouchBalloonProvider")
        }
        guard let payloadClass = NSClassFromString("IMPluginPayload"),
              let dataSourceClass = NSClassFromString("ETBalloonPluginDataSource"),
              let controllerClass = NSClassFromString("ETMacBalloonPluginController") else {
            throw ErrorMessage("Digital Touch private classes are unavailable")
        }

        _ = NSApplication.shared

        let payload = try initObject(payloadClass, selector: "init")
        payload.setValue(payloadData, forKey: "data")
        payload.setValue(digitalTouchBalloonProviderBundleID, forKey: "pluginBundleID")
        payload.setValue(uuid, forKey: "messageGUID")
        payload.setValue(isFromMe, forKey: "isFromMe")

        let dataSource = try initObject(dataSourceClass, selector: "initWithPluginPayload:", payload)
        let controller = try initObject(controllerClass, selector: "initWithDataSource:isFromMe:", dataSource, isFromMe)
        guard let assetURL = try performObject(controller, selector: "getAssetURL") as? URL else {
            throw ErrorMessage("Digital Touch renderer didn't return an asset URL")
        }

        try? FileManager.default.removeItem(at: assetURL)
        if assetURL != destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        var completionFired = false
        let completion: @convention(block) () -> Void = {
            completionFired = true
        }
        _ = controller.perform(
            Selector(("_createFallbackMediaWithCompletion:")),
            with: unsafeBitCast(completion, to: AnyObject.self)
        )

        try waitForRenderedAsset(assetURL, completionFired: { completionFired })
        try copyRenderedAssetIfNeeded(from: assetURL, to: destinationURL)
        return destinationURL
    }

    @MainActor
    private static func initObject(_ cls: AnyClass, selector: String, _ args: Any?...) throws -> NSObject {
        guard let allocated = cls.alloc() as? NSObject else {
            throw ErrorMessage("Couldn't allocate \(NSStringFromClass(cls))")
        }
        let unmanaged: Unmanaged<AnyObject>?
        switch args.count {
        case 0:
            unmanaged = allocated.perform(Selector((selector)))
        case 1:
            unmanaged = allocated.perform(Selector((selector)), with: args[0])
        case 2:
            unmanaged = allocated.perform(Selector((selector)), with: args[0], with: args[1])
        default:
            throw ErrorMessage("Unsupported Digital Touch initializer arity")
        }
        return try object(from: unmanaged, method: selector)
    }

    @MainActor
    private static func performObject(_ object: NSObject, selector: String) throws -> AnyObject {
        try self.object(from: object.perform(Selector((selector))), method: selector)
    }

    @MainActor
    private static func object(from unmanaged: Unmanaged<AnyObject>?, method: String) throws -> NSObject {
        guard let unmanaged,
              let object = unmanaged.takeUnretainedValue() as? NSObject else {
            throw ErrorMessage("Digital Touch private method returned nil: \(method)")
        }
        return object
    }

    @MainActor
    private static func waitForRenderedAsset(_ url: URL, completionFired: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        var previousSize: UInt64 = 0
        var stableNonZeroSizeCount = 0

        while Date() <= deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))

            let size = fileSize(url)
            if size > 0, size == previousSize {
                stableNonZeroSizeCount += 1
            } else {
                stableNonZeroSizeCount = 0
            }
            if completionFired(), size > 0 {
                return
            }
            if stableNonZeroSizeCount >= 5 {
                return
            }
            previousSize = size
        }

        throw ErrorMessage("Timed out rendering Digital Touch asset")
    }

    private static func copyRenderedAssetIfNeeded(from renderedURL: URL, to destinationURL: URL) throws {
        guard fileSize(renderedURL) > 0 else {
            throw ErrorMessage("Digital Touch renderer produced an empty asset")
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

    private static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
}
