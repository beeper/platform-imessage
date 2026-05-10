import Foundation
import SQLiteData

public struct IMCoreDateRepresentation: QueryBindable {
    public typealias QueryValue = Int?

    public var queryOutput: Date?

    public var queryBinding: QueryBinding {
        queryOutput.map(\.nanosecondsSinceReferenceDate).queryBinding
    }

    public init(queryOutput: Date?) {
        self.queryOutput = queryOutput
    }

    public init(decoder: inout some QueryDecoder) throws {
        guard let nanoseconds = try Int?(decoder: &decoder) else {
            queryOutput = nil
            return
        }

        // For unknown reasons `0` can be present instead of `NULL`. Treat them as the same.
        guard nanoseconds > 0 else {
            queryOutput = nil
            return
        }

        // Explicitly check for bogus dates. If you let these escape into the rest of the
        // program then an integer overflow might make everything implode.
        let date = Date(nanosecondsSinceReferenceDate: nanoseconds)
        queryOutput = date < .distantFuture ? date : nil
    }
}

public struct ZeroDefaultIntRepresentation: QueryBindable {
    public typealias QueryValue = Int

    public var queryOutput: Int

    public var queryBinding: QueryBinding {
        queryOutput.queryBinding
    }

    public init(queryOutput: Int) {
        self.queryOutput = queryOutput
    }

    public init(decoder: inout some QueryDecoder) throws {
        queryOutput = try Int?(decoder: &decoder) ?? 0
    }
}

public struct LooseBoolRepresentation: QueryBindable {
    public typealias QueryValue = Int

    public var queryOutput: Bool

    public var queryBinding: QueryBinding {
        (queryOutput ? 1 : 0).queryBinding
    }

    public init(queryOutput: Bool) {
        self.queryOutput = queryOutput
    }

    public init(decoder: inout some QueryDecoder) throws {
        queryOutput = try Int?(decoder: &decoder) == 1
    }
}
