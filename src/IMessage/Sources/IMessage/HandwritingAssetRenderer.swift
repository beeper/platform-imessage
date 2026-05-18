#if !IMESSAGE_DISABLE_PRIVATE_SPI_ASSETS
import Foundation
import IMessageCore
import IMessagePrivateSPI

private let handwritingProviderPath = "/System/Library/Messages/iMessageBalloons/HandwritingProvider.bundle"
private let handwritingAssetDescription = "Handwriting"
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
        isCancelled: @escaping RenderCancellation
    ) throws -> URL {
        try AssetSupport.loadBundle(path: handwritingProviderPath, assetDescription: "HandwritingProvider")
        AssetSupport.prepareRenderThread()

        let payload = try AssetSupport.makePluginPayload(
            payloadData: payloadData,
            bundleID: BalloonBundleKind.handwriting.rawValue,
            messageGUID: messageGUID,
            isFromMe: isFromMe
        )

        let dataSource = try AssetSupport.makePluginPayloadDataSource(
            className: "HWBalloonDataSource",
            payload: payload,
            assetDescription: handwritingAssetDescription
        )
        guard let handwritingItem = IMPrivateSPIHandwritingFromPayload(dataSource) else {
            throw ErrorMessage("Handwriting renderer couldn't decode payload")
        }

        let renderedURL = try writeThumbnail(
            handwritingItem: handwritingItem,
            isCancelled: isCancelled
        )
        defer { AssetSupport.removeIfDifferent(renderedURL, from: destinationURL) }
        try AssetSupport.copyRenderedAsset(from: renderedURL, to: destinationURL, assetDescription: handwritingAssetDescription)
        return destinationURL
    }

    private static func writeThumbnail(
        handwritingItem: NSObject,
        isCancelled: @escaping RenderCancellation
    ) throws -> URL {
        let renderedURL = Protected<URL?>()
        let shouldRemoveRenderedURL = Protected(false)
        guard IMPrivateSPIHandwritingWriteThumbnail("HWAbstractBalloonController", handwritingItem, renderedSize, true, { url in
            renderedURL.withLock { $0 = url }
            if shouldRemoveRenderedURL.read() {
                try? FileManager.default.removeItem(at: url)
            }
        }) else {
            throw ErrorMessage("Handwriting private class HWAbstractBalloonController is unavailable")
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
#endif
