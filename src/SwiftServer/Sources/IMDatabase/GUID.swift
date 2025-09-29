import SQLite

public struct GUID<Tag>: Sendable {
    var guts: String

    init(_ guts: String) {
        self.guts = guts
    }
}

extension GUID: Equatable {}

extension GUID: Hashable {}

extension GUID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.guts = value
    }
}

extension GUID: SQLiteBindable {
    public func unsafeBind(toPreparedStatement handle: OpaquePointer, at parameterIndex: Int32) throws {
        try guts.unsafeBind(toPreparedStatement: handle, at: parameterIndex)
    }
}

extension GUID: CustomStringConvertible {
    public var description: String {
        guts
    }
}
