import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import ObjectiveC

private let handwritingProviderPath = "/System/Library/Messages/iMessageBalloons/HandwritingProvider.bundle"
private let handwritingProviderBundleID = "com.apple.Handwriting.HandwritingProvider"
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
        try await AssetSupport.onRenderQueue {
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
        guard Bundle(path: handwritingProviderPath)?.load() == true else {
            throw ErrorMessage("Couldn't load HandwritingProvider")
        }
        guard let payloadClass = NSClassFromString("IMPluginPayload"),
              let dataSourceClass = NSClassFromString("HWBalloonDataSource"),
              let rendererClass = NSClassFromString("HWAbstractBalloonController") else {
            throw ErrorMessage("Handwriting private classes are unavailable")
        }

        Thread.current.name = "Plugin Payload Asset Renderer"
        _ = NSApplication.shared

        let payload = try AssetSupport.initObject(payloadClass, selector: #selector(NSObject.init))
        payload.setValue(payloadData, forKey: "data")
        payload.setValue(handwritingProviderBundleID, forKey: "pluginBundleID")
        payload.setValue(messageGUID, forKey: "messageGUID")
        payload.setValue(isFromMe, forKey: "isFromMe")

        let dataSource = try AssetSupport.initObject(dataSourceClass, selector: Selector(("initWithPluginPayload:")), payload)
        guard let handwritingItem = try AssetSupport.performObject(dataSource, selector: Selector(("handwritingFromPayload"))) as? NSObject else {
            throw ErrorMessage("Handwriting renderer couldn't decode payload")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let renderedURL = try writeThumbnail(handwritingItem: handwritingItem, rendererClass: rendererClass)
        try AssetSupport.copyRenderedAsset(from: renderedURL, to: destinationURL, assetDescription: handwritingAssetDescription)
        return destinationURL
    }

    private static func writeThumbnail(handwritingItem: NSObject, rendererClass: AnyClass) throws -> URL {
        let selector = Selector(("_writeThumbnailOfHandwriting:atSize:useHighFidelityInk:toDiskWithCompletionHandler:"))
        guard let method = class_getClassMethod(rendererClass, selector) else {
            throw ErrorMessage("Handwriting renderer method is unavailable")
        }

        let renderedURL = Protected<URL?>()
        let completion: @convention(block) (URL?) -> Void = { url in
            renderedURL.withLock { $0 = url }
        }
        typealias WriteThumbnailIMP = @convention(c) (AnyClass, Selector, AnyObject, CGSize, Bool, AnyObject) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: WriteThumbnailIMP.self)
        implementation(
            rendererClass,
            selector,
            handwritingItem,
            renderedSize,
            true,
            unsafeBitCast(completion, to: AnyObject.self)
        )

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
