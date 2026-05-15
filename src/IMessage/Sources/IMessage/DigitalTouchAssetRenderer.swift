import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import IMessagePrivateSPI
import ObjectiveC

private let digitalTouchBalloonProviderPath = "/System/Library/Messages/iMessageBalloons/DigitalTouchBalloonProvider.bundle"
private let digitalTouchAssetDescription = "Digital Touch"
private let digitalTouchRenderTimeout: TimeInterval = 30
private let renderRunLoopInterval: TimeInterval = 0.1

private typealias AssetSupport = PluginPayloadAssetSupport

enum DigitalTouchAssetRenderer {
    static func render(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) async throws -> URL {
        guard AssetSupport.fileSize(destinationURL) == 0 else {
            return destinationURL
        }
        return try await AssetSupport.onRenderQueue {
            try ExceptionCatcher.catch {
                try renderOnRenderQueue(payloadData: payloadData, uuid: uuid, isFromMe: isFromMe, destinationURL: destinationURL)
            }
        }
    }

    private static func renderOnRenderQueue(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) throws -> URL {
        guard AssetSupport.fileSize(destinationURL) == 0 else {
            return destinationURL
        }
        guard Bundle(path: digitalTouchBalloonProviderPath)?.load() == true else {
            throw ErrorMessage("Couldn't load DigitalTouchBalloonProvider")
        }
        guard let payloadClass = NSClassFromString("IMPluginPayload") as? NSObject.Type,
              let dataSourceClass = NSClassFromString("ETBalloonPluginDataSource") as? NSObject.Type,
              let controllerClass = NSClassFromString("ETMacBalloonPluginController") as? NSObject.Type else {
            throw ErrorMessage("Digital Touch private classes are unavailable")
        }

        Thread.current.name = "Plugin Payload Asset Renderer"
        _ = NSApplication.shared

        let payload = payloadClass.init()
        payload.data = payloadData
        payload.pluginBundleID = BalloonBundleID.digitalTouch
        payload.messageGUID = uuid
        payload.isFromMe = isFromMe

        let dataSource = dataSourceClass.init(pluginPayload: payload)
        let controller = controllerClass.init(dataSource: dataSource, isFromMe: isFromMe)
        guard let assetURL = controller.getAssetURL() else {
            throw ErrorMessage("Digital Touch renderer didn't return an asset URL")
        }

        try? FileManager.default.removeItem(at: assetURL)

        let completionFired = Protected(false)
        controller.createFallbackMedia {
            completionFired.withLock { $0 = true }
        }

        try waitForRenderedAsset(assetURL, completionFired: completionFired.read)
        defer {
            if assetURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: assetURL)
            }
        }
        try AssetSupport.copyRenderedAsset(from: assetURL, to: destinationURL, assetDescription: digitalTouchAssetDescription)
        return destinationURL
    }

    private static func waitForRenderedAsset(_ url: URL, completionFired: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(digitalTouchRenderTimeout)

        while Date() <= deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: renderRunLoopInterval))

            let size = AssetSupport.fileSize(url)
            if completionFired(), size > 0 {
                return
            }
        }

        throw ErrorMessage("Timed out rendering Digital Touch asset")
    }
}
