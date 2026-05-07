import GRDB

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

extension GUID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        guts.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> GUID? {
        guard let string = String.fromDatabaseValue(dbValue) else {
            return nil
        }
        return GUID(string)
    }
}

extension GUID: CustomStringConvertible {
    public var description: String {
        guts
    }
}
