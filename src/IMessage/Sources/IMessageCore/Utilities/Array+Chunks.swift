public extension Array {
    package func chunks(ofCount size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        return stride(from: startIndex, to: endIndex, by: size).map { start in
            self[start ..< Swift.min(start + size, endIndex)]
        }
    }
}
