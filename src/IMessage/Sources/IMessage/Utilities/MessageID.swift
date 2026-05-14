// 06FC451C-4E1A-4411-9DBA-BF1005E0AD2C_2 → 06FC451C-4E1A-4411-9DBA-BF1005E0AD2C
@inlinable public func messageGUID(fromID id: String) -> String {
    guard let underscoreIndex = id.firstIndex(of: "_") else { return id }
    return String(id[..<underscoreIndex])
}
