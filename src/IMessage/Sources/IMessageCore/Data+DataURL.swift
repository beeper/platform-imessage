import Foundation

public extension Data {
    var dataURL: String { "data:;base64,\(base64EncodedString())" }
}

public extension NSData {
    var dataURL: String { (self as Data).dataURL }
}
