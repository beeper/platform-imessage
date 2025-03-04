func printOverrides() {
    let searchEngine = EMFEmojiSearchEngine(locale: .current)!
    let map = searchEngine.overrideList.value(forKey: "_overrideMap") as! [String: [String: Any]]
    // 0 = raw string exact match, 1 = raw string prefix match, 2 = exact match, 3 = prefix match
    for (overrideName, overri) in map.sorted(by: { $0.key < $1.key }) {
        let ov = EMFQueryResultOverride(
            overridesArray: overri["results"] as? [Any],
            searchType: overri["searchType"],
            behavior: overri["overrideBehaviorType"]
        )
        let out = if let rs = ov?.results {
            String(reflecting: rs)
        } else { "…" }
        print("\(overrideName): \(out)")
    }
}

func calculateMappings() async throws {
    let mapping = AppleEmojiNames.mapping.flatMap { $0 as? [String: String] }
    let langs = CPKDefaultDataSource.preferredLanguagesForSearch()
    guard let mapping else { fatalError("no emoji name mapping") }

    await withTaskGroup(of: (String, String, Int?).self) { group in
        for (emoji, name) in mapping where !emoji.hasSuffix("@CH-SKU") /* china-only names */ {
            group.addTask {
                let searchQueries = [
                    name,
                    name.replacing("flag of ", with: ""),
                    name.hasPrefix("family with") ? "family" : "",
                    name.split(separator: " ").first.map(String.init),
                ].compactMap { $0 }

                for (searchQueryIndex, searchQuery) in searchQueries.enumerated() {
                    let (searchResults, _) = await CPKDefaultDataSource.emojiTokens(forSearch: searchQuery, inLanguages: langs, maxResults: 500)
                    guard let index = searchResults?.firstIndex(where: { $0.string == emoji }) else { continue }
                    if searchQueryIndex != 0 {
                        print("[Alternative] \(emoji) was found using \"\(searchQuery)\"")
                    }
                    return (emoji, name, index)
                }

                print("[FAIL] couldn't find matching query+tabs for \(emoji), apple name: \"\(name)\"")
                return (emoji, name, nil)
            }
        }

        for await (emoji, name, index) in group {
            print(emoji, name, index.map(String.init) ?? "👎 NO MAPPING 👎")
        }
    }
}

// don't attempt casts to real types, it won't compile
CPKAttemptQueryingCPSearchManager("dog", { results in
    print("\(results)")
})
dispatchMain()
