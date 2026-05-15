import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import IMessagePrivateSPI
import ObjectiveC

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
        guard AssetSupport.fileSize(destinationURL) == 0 else {
            return destinationURL
        }
        return try await AssetSupport.onRenderQueue {
            try ExceptionCatcher.catch {
                try renderOnRenderQueue(
                    payloadData: payloadData,
                    messageGUID: messageGUID,
                    isFromMe: isFromMe,
                    destinationURL: destinationURL
                )
            }
        }
    }

    private static func renderOnRenderQueue(
        payloadData: Data,
        messageGUID: String,
        isFromMe: Bool,
        destinationURL: URL
    ) throws -> URL {
        guard AssetSupport.fileSize(destinationURL) == 0 else {
            return destinationURL
        }
        guard Bundle(path: handwritingProviderPath)?.load() == true else {
            throw ErrorMessage("Couldn't load HandwritingProvider")
        }
        guard let payloadClass = NSClassFromString("IMPluginPayload") as? NSObject.Type,
              let dataSourceClass = NSClassFromString("HWBalloonDataSource") as? NSObject.Type,
              let rendererClass = NSClassFromString("HWAbstractBalloonController") as? NSObject.Type else {
            throw ErrorMessage("Handwriting private classes are unavailable")
        }

        Thread.current.name = "Plugin Payload Asset Renderer"
        _ = NSApplication.shared

        let payload = payloadClass.init()
        payload.data = payloadData
        payload.pluginBundleID = BalloonBundleID.handwriting
        payload.messageGUID = messageGUID
        payload.isFromMe = isFromMe

        let dataSource = dataSourceClass.init(pluginPayload: payload)
        guard let handwritingItem = dataSource.handwritingFromPayload() else {
            throw ErrorMessage("Handwriting renderer couldn't decode payload")
        }

        let renderedURL = try writeThumbnail(handwritingItem: handwritingItem, rendererClass: rendererClass)
        defer {
            if renderedURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: renderedURL)
            }
        }
        try AssetSupport.copyRenderedAsset(from: renderedURL, to: destinationURL, assetDescription: handwritingAssetDescription)
        return destinationURL
    }

    private static func writeThumbnail(handwritingItem: Any, rendererClass: NSObject.Type) throws -> URL {
        let renderedURL = Protected<URL?>()
        rendererClass.writeThumbnail(
            of: handwritingItem,
            atSize: renderedSize,
            useHighFidelityInk: true
        ) { url in
            renderedURL.withLock { $0 = url }
        }

        let deadline = Date().addingTimeInterval(handwritingRenderTimeout)
        while Date() <= deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: renderRunLoopInterval))
            if let renderedURL = renderedURL.read(), AssetSupport.fileSize(renderedURL) > 0 {
                return renderedURL
            }
        }

        throw ErrorMessage("Timed out rendering handwriting asset")
    }
}
