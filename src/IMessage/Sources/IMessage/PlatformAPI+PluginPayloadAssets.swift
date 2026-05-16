import Foundation

private let pluginPayloadLegacyAssetPollInterval: TimeInterval = 0.1
private let fallbackPluginPayloadAssetWait: TimeInterval = 4

extension PlatformAPI {
    nonisolated static func withLegacyPluginPayloadAssetFallback(
        route: PluginPayloadAssetRoute,
        _ operation: () async throws -> AssetResult
    ) async throws -> AssetResult {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let primaryError = error
            if let fallback = try? await legacyPluginPayloadAsset(route: route) {
                return fallback
            }
            throw primaryError
        }
    }

    nonisolated private static func legacyPluginPayloadAsset(route: PluginPayloadAssetRoute) async throws -> AssetResult? {
        switch route.kind {
        case .handwriting:
            return try await waitForExistingHandwritingAssetURL(uuid: route.uuid)
                .map { .url(fileURLString($0.path)) }

        case .digitalTouch:
            return try await waitForExistingDigitalTouchAssetURL(uuid: route.uuid)
                .map { .url(fileURLString($0.path)) }
        }
    }

    nonisolated private static func firstExistingAssetURL(_ candidates: [URL]) -> URL? {
        candidates.first(where: { PluginPayloadAssetSupport.fileSize($0) > 0 })
    }

    nonisolated private static func contentsOfDirectoryIfPresent(_ directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        } catch {
            let nsError = error as NSError
            let noSuchFileErrorCodes = [
                CocoaError.Code.fileReadNoSuchFile.rawValue,
                CocoaError.Code.fileNoSuchFile.rawValue,
            ]
            if nsError.domain == NSCocoaErrorDomain,
               noSuchFileErrorCodes.contains(nsError.code) {
                return []
            }
            throw error
        }
    }

    nonisolated private static func handwritingAssetFilename(uuid: String) -> String {
        "hw_\(uuid)_\(Int(HandwritingAssetRenderer.renderedSize.width))_\(Int(HandwritingAssetRenderer.renderedSize.height))_dark.png"
    }

    nonisolated private static func existingLegacyHandwritingAssetURL(uuid: String) throws -> URL? {
        let prefix = "hw_\(uuid)_"
        return try firstExistingAssetURL([
            MessagesPaths.temporaryMobileSMSDirectory,
            MessagesPaths.temporaryDirectory,
        ].flatMap { directory in
            try contentsOfDirectoryIfPresent(directory)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        })
    }

    nonisolated private static func existingHandwritingAssetURL(uuid: String) throws -> URL? {
        let fileName = handwritingAssetFilename(uuid: uuid)
        if let exactURL = firstExistingAssetURL([
            MessagesPaths.temporaryMobileSMSDirectory.appendingPathComponent(fileName),
            MessagesPaths.temporaryDirectory.appendingPathComponent(fileName),
        ]) {
            return exactURL
        }
        return try existingLegacyHandwritingAssetURL(uuid: uuid)
    }

    nonisolated private static func waitForExistingHandwritingAssetURL(uuid: String) async throws -> URL? {
        try await waitForFileURL(maxWait: fallbackPluginPayloadAssetWait, pollInterval: pluginPayloadLegacyAssetPollInterval) {
            try existingHandwritingAssetURL(uuid: uuid)
        }
    }

    nonisolated private static func existingDigitalTouchAssetURL(uuid: String) -> URL? {
        firstExistingAssetURL([
            MessagesPaths.temporaryMobileSMSDirectory.appendingPathComponent("\(uuid).mov"),
            MessagesPaths.temporaryDirectory.appendingPathComponent("\(uuid).mov"),
        ])
    }

    nonisolated private static func waitForExistingDigitalTouchAssetURL(uuid: String) async throws -> URL? {
        try await waitForFileURL(maxWait: fallbackPluginPayloadAssetWait, pollInterval: pluginPayloadLegacyAssetPollInterval) {
            existingDigitalTouchAssetURL(uuid: uuid)
        }
    }
}
