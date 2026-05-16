import AppKit
import Foundation
import IMessageCore
import IMessagePrivateSPI

private let digitalTouchBalloonProviderPath = "/System/Library/Messages/iMessageBalloons/DigitalTouchBalloonProvider.bundle"
private let digitalTouchAssetDescription = "Digital Touch"
private let digitalTouchBalloonProviderDescription = "DigitalTouchBalloonProvider"
private let digitalTouchRenderTimeout: TimeInterval = 30
private let renderRunLoopInterval: TimeInterval = 0.1

private typealias AssetSupport = PluginPayloadAssetSupport

enum DigitalTouchAssetRenderer {
    static func render(payloadData: Data, uuid: String, isFromMe: Bool, destinationURL: URL) async throws -> URL {
        try await AssetSupport.renderIfNeeded(destinationURL: destinationURL) { isCancelled in
            try renderOnRenderQueue(
                payloadData: payloadData,
                uuid: uuid,
                isFromMe: isFromMe,
                destinationURL: destinationURL,
                isCancelled: isCancelled
            )
        }
    }

    private static func renderOnRenderQueue(
        payloadData: Data,
        uuid: String,
        isFromMe: Bool,
        destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL {
        try AssetSupport.loadBundle(
            path: digitalTouchBalloonProviderPath,
            assetDescription: digitalTouchBalloonProviderDescription
        )
        let payloadClass: IMPluginPayload.Type = try AssetSupport.privateClass(
            "IMPluginPayload",
            as: IMPluginPayload.Type.self,
            assetDescription: digitalTouchAssetDescription
        )
        let dataSourceClass: ETBalloonPluginDataSource.Type = try AssetSupport.privateClass(
            "ETBalloonPluginDataSource",
            as: ETBalloonPluginDataSource.Type.self,
            assetDescription: digitalTouchAssetDescription
        )
        let controllerClass: ETMacBalloonPluginController.Type = try AssetSupport.privateClass(
            "ETMacBalloonPluginController",
            as: ETMacBalloonPluginController.Type.self,
            assetDescription: digitalTouchAssetDescription
        )

        AssetSupport.prepareRenderThread()

        let payload = AssetSupport.makePluginPayload(
            payloadClass: payloadClass,
            payloadData: payloadData,
            bundleID: BalloonBundleID.digitalTouch,
            messageGUID: uuid,
            isFromMe: isFromMe
        )

        let dataSource = dataSourceClass.init(pluginPayload: payload)
        let controller = controllerClass.init(dataSource: dataSource, isFromMe: isFromMe)
        guard let assetURL = controller.getAssetURL() else {
            throw ErrorMessage("Digital Touch renderer didn't return an asset URL")
        }

        let shouldRemoveAsset = assetURL.standardizedFileURL != destinationURL.standardizedFileURL
        defer {
            if shouldRemoveAsset {
                try? FileManager.default.removeItem(at: assetURL)
            }
        }
        try? FileManager.default.removeItem(at: assetURL)

        let completionFired = Protected(false)
        controller.createFallbackMedia {
            completionFired.withLock { $0 = true }
        }

        let renderedURL = try AssetSupport.waitForRenderedAsset(
            assetDescription: digitalTouchAssetDescription,
            timeout: digitalTouchRenderTimeout,
            pollInterval: renderRunLoopInterval,
            isCancelled: isCancelled
        ) {
            completionFired.read() ? assetURL : nil
        }
        try AssetSupport.copyRenderedAsset(from: renderedURL, to: destinationURL, assetDescription: digitalTouchAssetDescription)
        return destinationURL
    }
}
