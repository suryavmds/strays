import Foundation

/// Subsequence matching for the command palette: `stnx` finds "Stop next dev".
public enum FuzzyMatcher {
    /// Nil when the query's characters do not appear in order in the
    /// candidate. Otherwise a score, higher for tighter and earlier matches.
    public static func score(query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())

        var score = 0
        var matched = 0
        var previousIndex = -2
        for (index, character) in haystack.enumerated() where matched < needle.count && character == needle[matched] {
            score += 1
            if index == previousIndex + 1 { score += 6 }
            if index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber) { score += 4 }
            previousIndex = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        // Among equal matches, prefer the shorter candidate.
        return score * 4 - haystack.count / 8
    }

    /// The items whose text matches, best first. Ties keep their input order.
    public static func rank<Item>(_ items: [Item], query: String, by text: (Item) -> String) -> [Item] {
        guard !query.allSatisfy(\.isWhitespace) else { return items }

        var scored: [(offset: Int, score: Int)] = []
        for (offset, item) in items.enumerated() {
            if let score = score(query: query, in: text(item)) {
                scored.append((offset, score))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.offset < rhs.offset : lhs.score > rhs.score
        }
        return scored.map { items[$0.offset] }
    }
}
