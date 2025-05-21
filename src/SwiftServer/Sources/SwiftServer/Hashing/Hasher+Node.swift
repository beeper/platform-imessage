import NodeAPI

extension Hasher: NodeValueConvertible {
    public func nodeValue() throws -> any NodeValue {
        try [
            "tokenizeRemembering": try NodeFunction(name: "tokenizeRemembering", callback: self.tokenizeRemembering(pii:)),
            "recoverOriginal": try NodeFunction(name: "recover", callback: self.recoverOriginal(fromToken:))
        ].nodeValue()
    }
}
