import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CgBIPNG {
    private static let pngHeader = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

    static func dataForAsset(_ data: Data) -> Data? {
        guard data.starts(with: pngHeader) else {
            return nil
        }
        guard data.range(of: Data("CgBI".utf8)) != nil else {
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let converted = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(converted, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return converted as Data
    }
}
