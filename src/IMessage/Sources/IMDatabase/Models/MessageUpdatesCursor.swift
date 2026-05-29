import Foundation

public struct MessageUpdatesCursor: Sendable {
    public let lastRowID: Int
    public let lastDateReadNanoseconds: Int64
    public let lastDateEditedNanoseconds: Int64

    public init(lastRowID: Int, lastDateReadNanoseconds: Int64, lastDateEditedNanoseconds: Int64) {
        self.lastRowID = lastRowID
        self.lastDateReadNanoseconds = lastDateReadNanoseconds
        self.lastDateEditedNanoseconds = lastDateEditedNanoseconds
    }

    public static let empty = MessageUpdatesCursor(
        lastRowID: 0,
        lastDateReadNanoseconds: 0,
        lastDateEditedNanoseconds: 0
    )
}
