import Foundation

/// Matches what someone said or typed ("horizontal", "Horizontal App")
/// against repository names ("Horizontal", "horizontal-app"), for Siri and
/// Shortcuts.
enum RepositoryMatching {
    /// The items whose names match `query`, best first: the same name, then
    /// names that start with it, then names with a word that starts with
    /// it, then names that contain it. Case, accents, spaces and
    /// punctuation do not count. An empty query matches nothing.
    static func matches<Item>(_ query: String, in items: [Item], name: (Item) -> String) -> [Item] {
        let wanted = comparable(query)
        guard !wanted.isEmpty else { return [] }
        let ranked = items.enumerated().compactMap { index, item -> (rank: Int, name: String, index: Int)? in
            rank(of: name(item), for: wanted).map { ($0, name(item), index) }
        }
        return ranked.sorted { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.index < second.index : order == .orderedAscending
        }
        .map { items[$0.index] }
    }

    /// 0 for the same name, up to 3 for containing it; `nil` for no match.
    private static func rank(of name: String, for wanted: String) -> Int? {
        let whole = comparable(name)
        if whole == wanted { return 0 }
        if whole.hasPrefix(wanted) { return 1 }
        if words(of: name).contains(where: { comparable($0).hasPrefix(wanted) }) { return 2 }
        if whole.contains(wanted) { return 3 }
        return nil
    }

    /// Lowercased letters and digits only, without accents.
    static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// The words in a name: split at spaces and punctuation, and where a
    /// lowercase letter meets a capital (`wyeApp` is `wye`, `App`).
    private static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if !character.isLetter && !character.isNumber {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if character.isUppercase, previous?.isLowercase == true, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
