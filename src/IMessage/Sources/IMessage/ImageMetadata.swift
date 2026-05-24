import Foundation
import ImageIO

struct ImageMetadata: Sendable {
    let width: Int
    let height: Int
}

enum ImageMetadataReader {
    private static let cache: NSCache<NSString, CachedImageMetadata> = {
        let cache = NSCache<NSString, CachedImageMetadata>()
        cache.countLimit = 2048
        return cache
    }()

    static func cachedRead(from filePath: String, byteCount: Int? = nil) -> ImageMetadata? {
        guard let key = cacheKey(filePath: filePath, byteCount: byteCount) else {
            return read(from: filePath)
        }
        let nsCacheKey = key as NSString

        if let cached = cache.object(forKey: nsCacheKey) {
            return cached.metadata
        }

        let metadata = read(from: filePath)
        cache.setObject(CachedImageMetadata(metadata), forKey: nsCacheKey)
        return metadata
    }

    static func read(from filePath: String) -> ImageMetadata? {
        let url = URL(fileURLWithPath: filePath)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        guard
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        // EXIF orientations 5–8 indicate a 90°/270° rotation, so width/height are swapped.
        // https://exiftool.org/TagNames/EXIF.html
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? ImageMetadata(width: height, height: width)
            : ImageMetadata(width: width, height: height)
    }

    private static func cacheKey(filePath: String, byteCount: Int?) -> String? {
        let url = URL(fileURLWithPath: filePath).standardizedFileURL
        if let byteCount {
            return "\(url.path)\u{0}\(byteCount)"
        }
        guard let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return "\(url.path)\u{0}\(byteCount.uint64Value)"
    }

    private final class CachedImageMetadata {
        let metadata: ImageMetadata?

        init(_ metadata: ImageMetadata?) {
            self.metadata = metadata
        }
    }
}
