import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import ObjectiveC

private let digitalTouchBalloonProviderPath = "/System/Library/Messages/iMessageBalloons/DigitalTouchBalloonProvider.bundle"
private let digitalTouchBalloonProviderBundleID = "com.apple.DigitalTouchBalloonProvider"
private let digitalTouchAssetDescription = "Digital Touch"
private let digitalTouchRenderTimeout: TimeInterval = 30
private let renderRunLoopInterval: TimeInterval = 0.1
private let stableFileSizeCheckCount = 5

private typealias AssetSupport = PluginPayloadAssetSupport

enum DigitalTouchAssetRenderer {
    static func render(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) async throws -> URL {
        try await AssetSupport.onRenderQueue {
            try ExceptionCatcher.catch {
                try renderOnRenderQueue(payloadData: payloadData, uuid: uuid, isFromMe: isFromMe, destinationURL: destinationURL)
            }
        }
    }

    private static func renderOnRenderQueue(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) throws -> URL {
        guard Bundle(path: digitalTouchBalloonProviderPath)?.load() == true else {
            throw ErrorMessage("Couldn't load DigitalTouchBalloonProvider")
        }
        guard let payloadClass = NSClassFromString("IMPluginPayload"),
              let dataSourceClass = NSClassFromString("ETBalloonPluginDataSource"),
              let controllerClass = NSClassFromString("ETMacBalloonPluginController") else {
            throw ErrorMessage("Digital Touch private classes are unavailable")
        }

        Thread.current.name = "Plugin Payload Asset Renderer"
        _ = NSApplication.shared

        let payload = try AssetSupport.initObject(payloadClass, selector: #selector(NSObject.init))
        payload.setValue(payloadData, forKey: "data")
        payload.setValue(digitalTouchBalloonProviderBundleID, forKey: "pluginBundleID")
        payload.setValue(uuid, forKey: "messageGUID")
        payload.setValue(isFromMe, forKey: "isFromMe")

        let dataSource = try AssetSupport.initObject(dataSourceClass, selector: Selector(("initWithPluginPayload:")), payload)
        let controller = try AssetSupport.initObject(controllerClass, selector: Selector(("initWithDataSource:isFromMe:")), dataSource, isFromMe)
        guard let assetURL = try AssetSupport.performObject(controller, selector: Selector(("getAssetURL"))) as? URL else {
            throw ErrorMessage("Digital Touch renderer didn't return an asset URL")
        }

        try? FileManager.default.removeItem(at: assetURL)
        if assetURL != destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let completionFired = Protected(false)
        let completion: @convention(block) () -> Void = {
            completionFired.withLock { $0 = true }
        }
        _ = controller.perform(
            Selector(("_createFallbackMediaWithCompletion:")),
            with: unsafeBitCast(completion, to: AnyObject.self)
        )

        try waitForRenderedAsset(assetURL, completionFired: completionFired.read)
        try AssetSupport.copyRenderedAsset(from: assetURL, to: destinationURL, assetDescription: digitalTouchAssetDescription)
        return destinationURL
    }

    private static func waitForRenderedAsset(_ url: URL, completionFired: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(digitalTouchRenderTimeout)
        var previousSize = 0
        var stableNonZeroSizeCount = 0

        while Date() <= deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: renderRunLoopInterval))

            let size = AssetSupport.fileSize(url)
            if size > 0, size == previousSize {
                stableNonZeroSizeCount += 1
            } else {
                stableNonZeroSizeCount = 0
            }
            if completionFired(), size > 0 {
                return
            }
            if stableNonZeroSizeCount >= stableFileSizeCheckCount {
                return
            }
            previousSize = size
        }

        throw ErrorMessage("Timed out rendering Digital Touch asset")
    }
}
