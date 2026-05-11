import Foundation

public struct MessageUpdatesCursor: Sendable {
    public let lastRowID: Int
    public let lastDateRead: Date
    public let lastDateEdited: Date

    public init(lastRowID: Int, lastDateRead: Date, lastDateEdited: Date) {
        self.lastRowID = lastRowID
        self.lastDateRead = lastDateRead
        self.lastDateEdited = lastDateEdited
    }

    public static let empty = MessageUpdatesCursor(
        lastRowID: 0,
        lastDateRead: Date(nanosecondsSinceReferenceDate: 0),
        lastDateEdited: Date(nanosecondsSinceReferenceDate: 0)
    )
}
