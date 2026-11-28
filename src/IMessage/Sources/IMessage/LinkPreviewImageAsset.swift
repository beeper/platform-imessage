import Foundation
import IMessageCore
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

private let linkPreviewFetchTimeout: TimeInterval = 15
private let browserImageTypes: Set<String> = [
    UTType.png.identifier,
    UTType.jpeg.identifier,
    UTType.gif.identifier,
    UTType.webP.identifier,
]

enum LinkPreviewImageSlot: String {
    case image = "link-image"
    case icon = "link-icon"
}

struct LinkPreviewImageRoute {
    let slot: LinkPreviewImageSlot
    let attachmentGUID: String
    let linkURL: URL

    init(slot: LinkPreviewImageSlot, attachmentGUID: String, linkURL: URL) {
        self.slot = slot
        self.attachmentGUID = attachmentGUID
        self.linkURL = linkURL
    }

    init(slot: LinkPreviewImageSlot, methodName: String) throws {
        let parts = methodName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty,
              let urlString = String(data: Data([UInt8](hexString: parts[1])), encoding: .utf8),
              let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else {
            throw ErrorMessage("invalid link preview image route")
        }
        self.slot = slot
        attachmentGUID = String(parts[0])
        linkURL = url
    }

    var assetURL: String {
        "asset://$accountID/\(slot.rawValue)/\(attachmentGUID).\(Array(linkURL.absoluteString.utf8).hexString())"
    }

    var cacheURL: URL {
        MessagesPaths.temporaryPlatformAttachmentDirectory
            .appendingPathComponent("link-preview-images", isDirectory: true)
            .appendingPathComponent("\(slot.rawValue)-\(attachmentGUID)")
    }
}

enum LinkPreviewImageFetcher {
    private static let inFlight = Protected<[URL: Task<URL, Error>]>([:])

    static func cachedOrFetchedImage(route: LinkPreviewImageRoute) async throws -> URL {
        let destination = route.cacheURL
        if PluginPayloadAssetSupport.fileSize(destination) > 0 {
            return destination
        }
        let task = inFlight.withLock { tasks -> Task<URL, Error> in
            if let existing = tasks[destination] {
                return existing
            }
            let task = Task { try await fetch(route: route, destination: destination) }
            tasks[destination] = task
            return task
        }
        defer { inFlight.withLock { $0[destination] = nil } }
        return try await task.value
    }

    private static func fetch(route: LinkPreviewImageRoute, destination: URL) async throws -> URL {
        let provider = LPMetadataProvider()
        provider.timeout = linkPreviewFetchTimeout
        provider.shouldFetchSubresources = true
        let metadata = try await provider.startFetchingMetadata(for: route.linkURL)
        let itemProvider = switch route.slot {
        case .image: metadata.imageProvider
        case .icon: metadata.iconProvider
        }
        guard let itemProvider else {
            throw ErrorMessage("link has no \(route.slot == .image ? "image" : "icon")")
        }
        let data = try await loadImageData(from: itemProvider)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try browserDisplayableImageData(data).write(to: destination, options: .atomic)
        return destination
    }

    private static func loadImageData(from itemProvider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ErrorMessage("link image had no data"))
                }
            }
        }
    }

    private static func browserDisplayableImageData(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            throw ErrorMessage("link image isn't a readable image")
        }
        if browserImageTypes.contains(type) {
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ErrorMessage("link image couldn't be decoded")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ErrorMessage("couldn't create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ErrorMessage("couldn't encode link image as PNG")
        }
        return output as Data
    }
}
