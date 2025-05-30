// https://stackoverflow.com/a/47476781
public extension Sequence<UInt8> {
    private static var hexAlphabet: [UnicodeScalar] {
        Array("0123456789abcdef".unicodeScalars)
    }

    func hexString() -> String {
        String(reduce(into: "".unicodeScalars) { result, value in
            result.append(Self.hexAlphabet[Int(value / 0x10)])
            result.append(Self.hexAlphabet[Int(value % 0x10)])
        })
    }
}

// https://stackoverflow.com/a/33548238
public extension [UInt8] {
    init(hexString: some StringProtocol) {
        var startIndex = hexString.startIndex
        self = (0 ..< hexString.count / 2).compactMap { _ in
            let endIndex = hexString.index(after: startIndex)
            defer { startIndex = hexString.index(after: endIndex) }
            return UInt8(hexString[startIndex ... endIndex], radix: 16)
        }
    }
}
