import AppKit
import ExceptionCatcher
import Foundation
import IMessageCore
import ObjectiveC

private let handwritingProviderPath = "/System/Library/Messages/iMessageBalloons/HandwritingProvider.bundle"
private let handwritingProviderBundleID = "com.apple.Handwriting.HandwritingProvider"

enum HandwritingAssetRenderer {
    static let renderedSize = CGSize(width: 400, height: 200)

    static func render(
        payloadData: Data,
        uuid: String,
        messageGUID: String,
        isFromMe: Bool,
        destinationURL: URL
    ) async throws -> URL {
        try await MainActor.run {
            try ExceptionCatcher.catch {
                try renderOnMainThread(
                    payloadData: payloadData,
                    uuid: uuid,
                    messageGUID: messageGUID,
                    isFromMe: isFromMe,
                    destinationURL: destinationURL
                )
            }
        }
    }

    @MainActor
    private static func renderOnMainThread(
        payloadData: Data,
        uuid: String,
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

        _ = NSApplication.shared

        let payload = try initObject(payloadClass, selector: "init")
        payload.setValue(payloadData, forKey: "data")
        payload.setValue(handwritingProviderBundleID, forKey: "pluginBundleID")
        payload.setValue(messageGUID, forKey: "messageGUID")
        payload.setValue(isFromMe, forKey: "isFromMe")

        let dataSource = try initObject(dataSourceClass, selector: "initWithPluginPayload:", payload)
        guard let handwritingItem = try performObject(dataSource, selector: "handwritingFromPayload") as? NSObject else {
            throw ErrorMessage("Handwriting renderer couldn't decode payload")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        let renderedURL = try writeThumbnail(handwritingItem: handwritingItem, rendererClass: rendererClass)
        try copyRenderedAssetIfNeeded(from: renderedURL, to: destinationURL)
        return destinationURL
    }

    @MainActor
    private static func writeThumbnail(handwritingItem: NSObject, rendererClass: AnyClass) throws -> URL {
        let selector = Selector(("_writeThumbnailOfHandwriting:atSize:useHighFidelityInk:toDiskWithCompletionHandler:"))
        guard let method = class_getClassMethod(rendererClass, selector) else {
            throw ErrorMessage("Handwriting renderer method is unavailable")
        }

        var renderedURL: URL?
        var completionFired = false
        let completion: @convention(block) (URL?) -> Void = { url in
            renderedURL = url
            completionFired = true
        }
        typealias WriteThumbnailIMP = @convention(c) (AnyObject, Selector, AnyObject, CGSize, Bool, AnyObject) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: WriteThumbnailIMP.self)
        implementation(
            rendererClass,
            selector,
            handwritingItem,
            renderedSize,
            true,
            unsafeBitCast(completion, to: AnyObject.self)
        )

        let deadline = Date().addingTimeInterval(15)
        while Date() <= deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            if completionFired, let renderedURL, fileSize(renderedURL) > 0 {
                return renderedURL
            }
        }

        throw ErrorMessage("Timed out rendering handwriting asset")
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
        default:
            throw ErrorMessage("Unsupported handwriting initializer arity")
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
            throw ErrorMessage("Handwriting private method returned nil: \(method)")
        }
        return object
    }

    private static func copyRenderedAssetIfNeeded(from renderedURL: URL, to destinationURL: URL) throws {
        guard fileSize(renderedURL) > 0 else {
            throw ErrorMessage("Handwriting renderer produced an empty asset")
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
