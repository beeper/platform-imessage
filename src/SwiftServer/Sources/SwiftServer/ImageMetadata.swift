import NodeAPI
import Foundation
import ImageIO

struct ImageMetadata {
    let width: Int
    let height: Int
    let orientation: Int?

    func nodeValue() -> [String: NodePropertyConvertible] {
        var value: [String: NodePropertyConvertible] = [
            "width": width,
            "height": height,
        ]
        if let orientation {
            value["orientation"] = orientation
        }
        return value
    }
}

enum ImageMetadataReader {
    static func read(from filePath: String) throws -> ImageMetadata? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return ImageMetadata(width: width, height: height, orientation: orientation)
    }
}
