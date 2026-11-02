import Foundation

/// Subsequence fuzzy matcher. Higher scores are better; nil means no match.
/// Rewards consecutive runs, matches at word starts and a prefix match.
/// Case, accents and full-width forms are ignored: "ecole" matches "École".
enum FuzzyMatcher {
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        // Folding can turn one character into several ("ß" into "ss"), so each
        // folded character remembers which original one it came from.
        let original = Array(candidate)
        var c: [Character] = [], from: [Int] = []
        for (k, ch) in original.enumerated() {
            for f in fold(String(ch)) { c.append(f); from.append(k) }
        }
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch: Int?
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            if firstMatch == nil { firstMatch = i }
            var s = 1
            let o = from[i]
            if lastMatch == i - 1 { s += 7 }                       // consecutive
            if i == 0 { s += 8 }                                    // prefix
            else if o > 0, from[i - 1] != o {
                let prev = original[o - 1]
                if " /-_.·@".contains(prev) { s += 4 }              // word start
                else if original[o].isUppercase && prev.isLowercase { s += 4 } // camelCase hump
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

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
