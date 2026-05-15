import Darwin
import Foundation
import IMessageCore

private let pluginPayloadAssetRenderQueue = DispatchQueue(
    label: "plugin-payload-asset-render-queue",
    qos: .utility
)

enum PluginPayloadAssetSupport {
    static func onRenderQueue<T>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            pluginPayloadAssetRenderQueue.async {
                continuation.resume(with: Result {
                    try autoreleasepool {
                        try action()
                    }
                })
            }
        }
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
}
