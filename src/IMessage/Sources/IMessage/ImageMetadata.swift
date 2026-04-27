import Foundation
import ImageIO

struct ImageMetadata: Sendable {
    let width: Int
    let height: Int
}

enum ImageMetadataReader {
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
}
