func messageID(messageGUID: String, partIndex: Int) -> String {
    partIndex == 0 ? messageGUID : "\(messageGUID)_\(partIndex)"
}

func messageDeletionIDs(messageGUID: String, partCount: Int, hasSubject: Bool) -> [String] {
    let normalizedPartCount = max(partCount, 1)
    var ids = [messageGUID]

    if hasSubject {
        ids.append(messageID(messageGUID: messageGUID, partIndex: -1))
    }

    ids.append(contentsOf: (1 ..< normalizedPartCount).map {
        messageID(messageGUID: messageGUID, partIndex: $0)
    })
    return ids
}
