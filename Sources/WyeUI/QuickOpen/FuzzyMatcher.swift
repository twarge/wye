import Foundation

/// How well a typed query matches a name, and which characters it matched.
struct FuzzyMatch: Equatable, Sendable {
    var score: Int
    /// Offsets of the matched characters in the name.
    var offsets: [Int]
}

/// Matches what was typed against names the way quick open does: every
/// typed character must appear in the name, in order, ignoring case. Among
/// the ways to place them, the best scoring one counts. Characters that run
/// together, start a word (after `/`, `-`, `_`, `.` or a space, or a capital
/// after a lowercase letter) or start the name score higher; characters
/// skipped between matches cost a little.
enum FuzzyMatcher {
    private static let matchScore = 16
    private static let consecutiveBonus = 12
    private static let wordStartBonus = 10
    private static let nameStartBonus = 8
    private static let exactCaseBonus = 1
    private static let gapPenalty = 1
    /// Skipping into the name costs less than skipping between matches:
    /// `main` should still find `feature/main`.
    private static let leadingGapPenalty = 0

    static func match(_ query: String, in name: String) -> FuzzyMatch? {
        let query = Array(query.filter { !$0.isWhitespace })
        let name = Array(name)
        guard !query.isEmpty else { return FuzzyMatch(score: 0, offsets: []) }
        guard query.count <= name.count else { return nil }
        let folded = name.map(fold)
        let foldedQuery = query.map(fold)

        // best[j]: the best score with the current query character at name
        // offset j; `from` remembers the previous character's offset.
        let none = Int.min / 2
        var previous = [Int](repeating: none, count: name.count)
        var from: [[Int]] = []

        for (i, character) in foldedQuery.enumerated() {
            var current = [Int](repeating: none, count: name.count)
            var links = [Int](repeating: -1, count: name.count)
            // The best of previous[k] + k over k < j - 1, so a gap's cost
            // is linear in its length without a loop over k.
            var bestBefore = none
            var bestBeforeOffset = -1
            for j in 0..<name.count {
                if j >= 2, i > 0, previous[j - 2] > none, previous[j - 2] + (j - 2) > bestBefore {
                    bestBefore = previous[j - 2] + (j - 2)
                    bestBeforeOffset = j - 2
                }
                guard folded[j] == character else { continue }
                let own = score(at: j, in: name) + (name[j] == query[i] ? exactCaseBonus : 0)
                if i == 0 {
                    current[j] = own - j * leadingGapPenalty
                    continue
                }
                var best = none
                var link = -1
                if j >= 1, previous[j - 1] > none {
                    best = previous[j - 1] + consecutiveBonus
                    link = j - 1
                }
                if bestBefore > none {
                    // previous[k] - (j - k - 1) * penalty, with penalty 1.
                    let gapped = bestBefore - (j - 1) * gapPenalty
                    if gapped > best {
                        best = gapped
                        link = bestBeforeOffset
                    }
                }
                if best > none {
                    current[j] = best + own
                    links[j] = link
                }
            }
            from.append(links)
            previous = current
        }

        guard let end = previous.indices.max(by: { previous[$0] < previous[$1] }), previous[end] > none else {
            return nil
        }
        var offsets = [end]
        for i in stride(from: foldedQuery.count - 1, to: 0, by: -1) {
            offsets.append(from[i][offsets.last!])
        }
        return FuzzyMatch(score: previous[end], offsets: offsets.reversed())
    }

    private static func score(at offset: Int, in name: [Character]) -> Int {
        var score = matchScore
        if offset == 0 {
            score += nameStartBonus + wordStartBonus
        } else {
            let before = name[offset - 1]
            if "/-_. ".contains(before) || (before.isLowercase && name[offset].isUppercase) {
                score += wordStartBonus
            }
        }
        return score
    }

    /// A character as compared: without case or accents. A string, since
    /// folding can turn one character into several.
    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
