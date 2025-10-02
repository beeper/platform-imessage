public extension Message {
    var parts: [Message.Part] {
        guard let body = attributedBody?.unwrappingSensitiveData() else {
            return []
        }

        let entire = NSRange(location: 0, length: body.length)

        var parts = [Message.Part]()
        body.enumerateAttribute(.imPart, in: entire) { rawIndex, range, stop in
            guard let index = rawIndex as? Int else {
                log.warning("encountered non-integer message part index: \(rawIndex, default: "nil")")
                return
            }

            parts.append(Message.Part(of: self, in: body, at: range, index: Message.Part.Index(rawValue: index)))
        }

        return parts.sorted(by: { $0.index < $1.index })
    }
}
