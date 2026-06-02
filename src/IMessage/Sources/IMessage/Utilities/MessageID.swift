// 06FC451C-4E1A-4411-9DBA-BF1005E0AD2C_2 → 06FC451C-4E1A-4411-9DBA-BF1005E0AD2C
@inlinable public func messageGUID(fromID id: String) -> String {
    messageIDParts(fromID: id).messageGUID
}

@usableFromInline func messageIDParts(fromID id: String) -> (messageGUID: String, partIndex: Int?) {
    guard let underscoreIndex = id.firstIndex(of: "_") else {
        return (id, nil)
    }

    let messageGUID = String(id[..<underscoreIndex])
    let partIndex = Int(id[id.index(after: underscoreIndex)...])
    return (messageGUID, partIndex)
}
