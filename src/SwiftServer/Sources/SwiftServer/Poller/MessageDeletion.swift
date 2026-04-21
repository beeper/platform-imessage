import Foundation

func messageID(messageGUID: String, partIndex: Int) -> String {
    partIndex == 0 ? messageGUID : "\(messageGUID)_\(partIndex)"
}

func messageDeletionIDs(messageGUID: String, partCount: Int, hasSubject: Bool) -> [String] {
    let normalizedPartCount = max(partCount, 1)
    var ids = Set((0 ..< normalizedPartCount).map { messageID(messageGUID: messageGUID, partIndex: $0) })

    if hasSubject {
        ids.insert(messageID(messageGUID: messageGUID, partIndex: -1))
    }

    return ids.sorted()
}
