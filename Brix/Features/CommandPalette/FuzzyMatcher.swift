import Foundation

/// Subsequence fuzzy matcher. Higher scores are better; nil means no match.
/// Rewards consecutive runs, matches at word starts and a prefix match.
enum FuzzyMatcher {
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch: Int?
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            if firstMatch == nil { firstMatch = i }
            var s = 1
            if lastMatch == i - 1 { s += 7 }                       // consecutive
            if i == 0 { s += 8 }                                    // prefix
            else {
                let prev = original[i - 1]
                if " /-_.·@".contains(prev) { s += 4 }              // word start
                else if original[i].isUppercase && prev.isLowercase { s += 4 } // camelCase hump
            }
            score += s
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates and earlier first matches.
        score -= min(c.count / 8, 6)
        score -= min((firstMatch ?? 0) / 4, 6)
        return score
    }
}
