import IMDatabase

// A bit gross, but `IMDatabase` shouldn't know what a hasher is.
extension ChatRef: CustomStringConvertible {
    public var description: String {
        if let guid {
            Hasher.thread.tokenizeRemembering(pii: guid)
        } else {
            "chat#\(rowID!)"
        }
    }
}
