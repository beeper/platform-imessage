import Foundation
import GRDB

extension Row {
    func optionalString(at index: Int) -> String? {
        self[index] as String?
    }

    func optionalInt(at index: Int) -> Int? {
        self[index] as Int?
    }

    func optionalData(at index: Int) -> Data? {
        self[index] as Data?
    }

    func requiredString(at index: Int) -> String {
        self[index] as String
    }

    func requiredInt(at index: Int) -> Int {
        self[index] as Int
    }

    func imCoreDate(at index: Int) -> Date? {
        guard let nanoseconds = optionalInt(at: index) else {
            return nil
        }

        // For unknown reasons `0` can be present instead of `NULL`. Treat them as the same.
        guard nanoseconds > 0 else {
            return nil
        }

        // Explicitly check for bogus dates. If you let these escape into the rest of the
        // program then an integer overflow might make everything implode.
        let date = Date(nanosecondsSinceReferenceDate: nanoseconds)
        guard date < .distantFuture else {
            return nil
        }

        return date
    }

    func looseBool(at index: Int) -> Bool {
        guard let integer = optionalInt(at: index) else {
            return false
        }

        return integer == 1
    }
}
