@available(macOS 11, *)
public struct CharacterPickerSearch {
    public var emoji: Character

    public var query: String

    /// zero-indexed
    public var position: Int

    public init(finding emoji: Character) throws {
        guard let localizedName = try CPKDefaultDataSource.localizedName(for: String(emoji)) else {
            throw Error.noLocalizedName
        }

        let searchEngine = try EMFEmojiSearchEngine()

        let queriesToAttempt = [
            localizedName,

            // these would only work on english locales:
            localizedName.replacingOccurrences(of: "flag of ", with: ""),
            localizedName.split(separator: " ").first.map(String.init),
            "flag",
        ].compactMap { $0 }

        let firstSuceedingQuery = try queriesToAttempt
            .lazy
            .compactMap { query -> (String, Int)? in
                let results = try searchEngine.query(query)
                guard !results.isEmpty,
                      let position = results.firstIndex(where: { $0.first?.withoutVariantSelectors == emoji.withoutVariantSelectors })
                else { return nil }
                return (query, position)
            }
            .first

        guard let firstSuceedingQuery else {
            // exhausted all queries, couldn't find where the emoji is in the picker
            throw Error.noSucceedingQuery
        }

        self.emoji = emoji
        (query, position) = firstSuceedingQuery
    }

    public enum Error: Swift.Error, Hashable {
        case noLocalizedName
        case noEmojiSearchEngine
        case noSucceedingQuery
    }
}

private extension Character {
    var withoutVariantSelectors: Character {
        // U+FE0F = "emoji variant, please"
        // U+FE0E = "text variant, please"
        Character(String(unicodeScalars.filter { $0 != "\u{fe0f}" && $0 != "\u{fe0e}" }))
    }
}
