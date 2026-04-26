import Foundation
import ImageIO
@testable import SwiftServer
import Testing

@Test func cgbiPNGIsConvertedToRegularPNG() throws {
    let url = try #require(Bundle.module.url(forResource: "cgbi-fixture", withExtension: "png"))
    let cgbiPNG = try Data(contentsOf: url)

    let converted = try #require(CgBIPNG.dataForAsset(cgbiPNG))

    #expect(converted.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])))
    #expect(converted.range(of: Data("CgBI".utf8)) == nil)
    #expect(converted != cgbiPNG)

    let imageSource = try #require(CGImageSourceCreateWithData(converted as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 128)
    #expect(image.height == 128)
}

@Test func nonPNGAssetDataReturnsNil() {
    #expect(CgBIPNG.dataForAsset(Data("not a png".utf8)) == nil)
}
