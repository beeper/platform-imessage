import AppKit
import Foundation
import IMessageCore
import IMessagePrivateSPI

private let handwritingProviderPath = "/System/Library/Messages/iMessageBalloons/HandwritingProvider.bundle"
private let handwritingAssetDescription = "Handwriting"
private let handwritingProviderDescription = "HandwritingProvider"
private let handwritingRenderedWidth = 400.0
private let handwritingRenderedHeight = 200.0
private let handwritingRenderTimeout: TimeInterval = 15
private let renderRunLoopInterval: TimeInterval = 0.1

private typealias AssetSupport = PluginPayloadAssetSupport

enum HandwritingAssetRenderer {
    static let renderedSize = CGSize(width: handwritingRenderedWidth, height: handwritingRenderedHeight)

    static func render(
        payloadData: Data,
        messageGUID: String,
        isFromMe: Bool,
        destinationURL: URL
    ) async throws -> URL {
        try await AssetSupport.renderIfNeeded(destinationURL: destinationURL) { isCancelled in
            try renderOnRenderQueue(
                payloadData: payloadData,
                messageGUID: messageGUID,
                isFromMe: isFromMe,
                destinationURL: destinationURL,
                isCancelled: isCancelled
            )
        }
    }

    private static func renderOnRenderQueue(
        payloadData: Data,
        messageGUID: String,
        isFromMe: Bool,
        destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL {
        try AssetSupport.loadBundle(
            path: handwritingProviderPath,
            assetDescription: handwritingProviderDescription
        )
        let payloadClass: IMPluginPayload.Type = try AssetSupport.privateClass(
            "IMPluginPayload",
            as: IMPluginPayload.Type.self,
            assetDescription: handwritingAssetDescription
        )
        let dataSourceClass: HWBalloonDataSource.Type = try AssetSupport.privateClass(
            "HWBalloonDataSource",
            as: HWBalloonDataSource.Type.self,
            assetDescription: handwritingAssetDescription
        )
        let rendererClass: HWAbstractBalloonController.Type = try AssetSupport.privateClass(
            "HWAbstractBalloonController",
            as: HWAbstractBalloonController.Type.self,
            assetDescription: handwritingAssetDescription
        )

        AssetSupport.prepareRenderThread()

        let payload = AssetSupport.makePluginPayload(
            payloadClass: payloadClass,
            payloadData: payloadData,
            bundleID: BalloonBundleID.handwriting,
            messageGUID: messageGUID,
            isFromMe: isFromMe
        )

        let dataSource = dataSourceClass.init(pluginPayload: payload)
        guard let handwritingItem = dataSource.handwritingFromPayload() else {
            throw ErrorMessage("Handwriting renderer couldn't decode payload")
        }

        let renderedURL = try writeThumbnail(
            handwritingItem: handwritingItem,
            rendererClass: rendererClass,
            isCancelled: isCancelled
        )
        defer {
            if renderedURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: renderedURL)
            }
        }
        try AssetSupport.copyRenderedAsset(from: renderedURL, to: destinationURL, assetDescription: handwritingAssetDescription)
        return destinationURL
    }

    private static func writeThumbnail(
        handwritingItem: Any,
        rendererClass: HWAbstractBalloonController.Type,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL {
        let renderedURL = Protected<URL?>()
        let shouldRemoveRenderedURL = Protected(false)
        rendererClass.writeThumbnail(
            of: handwritingItem,
            atSize: renderedSize,
            useHighFidelityInk: true
        ) { url in
            renderedURL.withLock { $0 = url }
            if shouldRemoveRenderedURL.read() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            return try AssetSupport.waitForRenderedAsset(
                assetDescription: "handwriting",
                timeout: handwritingRenderTimeout,
                pollInterval: renderRunLoopInterval,
                isCancelled: isCancelled,
                matching: renderedURL.read
            )
        } catch {
            shouldRemoveRenderedURL.withLock { $0 = true }
            if let renderedURL = renderedURL.read() {
                try? FileManager.default.removeItem(at: renderedURL)
            }
            throw error
        }
    }
}
