// iMessage;-;hi@kishan.info → hi@kishan.info
@inlinable func threadIDToAddress(_ threadID: String) -> String? {
    splitThreadID(threadID)?.2
}

// iMessage;-;hi@kishan.info → ("iMessage", "-", "hi@kishan.info")
@inlinable func splitThreadID(_ threadID: String) -> (String.SubSequence, String.SubSequence, String)? {
    let components = threadID.split(separator: ";", maxSplits: 2)
    guard components.count == 3 else { return nil }
    return (components[0], components[1], String(components[2]))
}

func singleParticipantAddress(_ threadID: String) -> String? {
    guard let (service, type, address) = splitThreadID(threadID),
          type == "-",
          service == "RCS" || service == "iMessage" || service == "any"
    else {
        return nil
    }
    return address
}

func threadIDIsForGroup(_ id: String) -> Bool {
    splitThreadID(id).map { $0.1 == MessagesDeepLink.groupThreadType } == true
}

// suffix match so "+15035550123" pairs with "5035550123"; require enough
// digits that shortcodes can't collide with a full number's tail
private let minimumPhoneSuffixDigits = 7

// Messages merges conversations per contact, so a send targeted at one chat can
// land in a sibling chat whose address is the same recipient with different
// formatting (email casing, or a phone with/without the country prefix). This
// runs before the contacts-database comparison, which can't see such pairs when
// the sent handle isn't on the contact card.
func addressesReferToSameRecipient(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
    if a.caseInsensitiveCompare(b) == .orderedSame { return true }
    guard !a.contains("@"), !b.contains("@") else { return false }
    let digitsA = a.filter(\.isNumber)
    let digitsB = b.filter(\.isNumber)
    guard min(digitsA.count, digitsB.count) >= minimumPhoneSuffixDigits else { return false }
    return digitsA.hasSuffix(digitsB) || digitsB.hasSuffix(digitsA)
}
