import Foundation
import SQLite

extension Column {
    consuming func imCoreDate() throws -> Date? {
        guard let nanoseconds = try optionalConverting(Int.self) else {
            return nil
        }

        return Date.imCoreDate(nanoseconds: nanoseconds)
    }

    consuming func looseBool() throws -> Bool {
        guard let integer = try optionalConverting(Int.self) else {
            return false
        }

        return integer == 1
    }
}
