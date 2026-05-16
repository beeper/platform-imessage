import AppKit
import Darwin
import ExceptionCatcher
import Foundation
import IMessageCore
#if !IMESSAGE_DISABLE_PRIVATE_SPI_ASSETS
import IMessagePrivateSPI
#endif

// Concurrent queue with a small permit semaphore: parallelism without unbounded growth.
// Permit count comes from validating Apple's HW/DT plugin SPIs against concurrent invocation.
// Drop to 1 (effectively serial) if a future macOS surfaces thread-safety issues.
private let pluginPayloadAssetRenderConcurrencyLimit = 3

private let pluginPayloadAssetRenderQueue = DispatchQueue(
    label: "plugin-payload-asset-render-queue",
    qos: .utility,
    attributes: .concurrent
)

private let pluginPayloadAssetRenderPermits = DispatchSemaphore(
    value: pluginPayloadAssetRenderConcurrencyLimit
)

typealias RenderCancellation = @Sendable () -> Bool

private struct RenderQueueWorkState<T> {
    var continuation: CheckedContinuation<T, Error>?
    var started = false
    var completed = false
    var isCancelled = false
}

enum PluginPayloadAssetSupport {
    static func onRenderQueue<T>(
        _ action: @escaping @Sendable (_ isCancelled: @escaping RenderCancellation) throws -> T
    ) async throws -> T {
        let state = Protected(RenderQueueWorkState<T>())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldEnqueue = state.withLock { work in
                    guard !work.isCancelled else {
                        return false
                    }
                    work.continuation = continuation
                    return true
                }
                guard shouldEnqueue else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pluginPayloadAssetRenderQueue.async {
                    // Bail without consuming a permit if cancellation already landed.
                    if state.withLock({ $0.isCancelled || $0.completed }) {
                        return
                    }
                    pluginPayloadAssetRenderPermits.wait()
                    defer { pluginPayloadAssetRenderPermits.signal() }

                    let continuation = state.withLock { work -> CheckedContinuation<T, Error>? in
                        guard !work.isCancelled, !work.completed else {
                            return nil
                        }
                        work.started = true
                        return work.continuation
                    }
                    guard let continuation else {
                        return
                    }

                    let isCancelled: RenderCancellation = {
                        state.withLock { $0.isCancelled }
                    }
                    let result = Result {
                        try autoreleasepool {
                            try action(isCancelled)
                        }
                    }
                    state.withLock { work in
                        work.completed = true
                        work.continuation = nil
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            let continuation = state.withLock { work -> CheckedContinuation<T, Error>? in
                work.isCancelled = true
                guard !work.started, !work.completed else {
                    return nil
                }
                work.completed = true
                let continuation = work.continuation
                work.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    static func renderIfNeeded(
        destinationURL: URL,
        _ render: @escaping @Sendable (_ isCancelled: @escaping RenderCancellation) throws -> URL
    ) async throws -> URL {
        guard fileSize(destinationURL) == 0 else {
            return destinationURL
        }
        return try await onRenderQueue { isCancelled in
            try checkCancellation(isCancelled)
            return try ExceptionCatcher.catch {
                try checkCancellation(isCancelled)
                guard fileSize(destinationURL) == 0 else {
                    return destinationURL
                }
                return try render(isCancelled)
            }
        }
    }

    static func checkCancellation(_ isCancelled: () -> Bool) throws {
        guard !isCancelled() else { throw CancellationError() }
    }

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

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: renderedURL, to: stagingURL)
        do {
            try atomicallyReplaceItem(at: destinationURL, with: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func atomicallyReplaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    return EINVAL
                }
                return rename(sourcePath, destinationPath) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    static func prepareRenderThread() {
        Thread.current.name = "Plugin Payload Asset Renderer"
        _ = NSApplication.shared
    }

    static func loadBundle(path: String, assetDescription: String) throws {
        guard Bundle(path: path)?.load() == true else {
            throw ErrorMessage("Couldn't load \(assetDescription)")
        }
    }

#if !IMESSAGE_DISABLE_PRIVATE_SPI_ASSETS
    static func privateClass<T>(_ className: String, assetDescription: String) throws -> T {
        guard let classObject = NSClassFromString(className) as? T else {
            throw ErrorMessage("\(assetDescription) private class \(className) is unavailable")
        }
        return classObject
    }

    static func removeIfDifferent(_ url: URL, from destinationURL: URL) {
        if url.standardizedFileURL != destinationURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func makePluginPayload(
        payloadData: Data,
        bundleID: String,
        messageGUID: String,
        isFromMe: Bool
    ) throws -> IMPluginPayload {
        let payloadClass: IMPluginPayload.Type = try privateClass(
            "IMPluginPayload",
            assetDescription: "Plugin payload"
        )
        let payload = payloadClass.init()
        payload.data = payloadData
        payload.pluginBundleID = bundleID
        payload.messageGUID = messageGUID
        payload.isFromMe = isFromMe
        return payload
    }
#endif

    static func waitForRenderedAsset(
        assetDescription: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        isCancelled: () -> Bool,
        matching assetURL: () -> URL?
    ) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            try checkCancellation(isCancelled)
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: pollInterval))
            try checkCancellation(isCancelled)

            if let url = assetURL(), fileSize(url) > 0 {
                return url
            }
        }

        throw ErrorMessage("Timed out rendering \(assetDescription) asset")
    }
}
