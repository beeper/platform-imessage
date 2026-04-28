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
