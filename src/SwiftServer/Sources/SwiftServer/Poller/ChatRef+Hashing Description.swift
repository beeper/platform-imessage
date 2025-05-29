import IMDatabase

// A bit gross, but `IMDatabase` shouldn't know what a hasher is.
extension ChatRef: @retroactive CustomStringConvertible {
    public var description: String {
        if let guid {
            Hasher.participant.tokenizeRemembering(pii: guid)
        } else {
            "chat#\(rowID!)"
        }
    }
}
