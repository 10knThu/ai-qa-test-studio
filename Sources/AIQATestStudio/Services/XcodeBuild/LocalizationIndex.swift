import Foundation

/// Read-only index of the app's `.strings` files: key → every localised value.
/// Issues are written in one language (e.g. Japanese design text) while the Simulator app may show another one
/// ("Shop注文履歴" in the issue, "Shop Order History" on screen), so every label is resolved to all its localisations.
struct LocalizationIndex: Sendable {
    /// key → all localised values (any language, de-duplicated, order preserved)
    private(set) var values: [String: [String]]

    private static let skippedFolders: Set<String> = ["Pods", "Carthage", ".build", "build", "DerivedData", "node_modules", "SourcePackages", ".git", "vendor", ".claude"]
    private static let entryRegex = try! NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"([^"]*)"\s*;"#, options: .anchorsMatchLines)

    init(values: [String: [String]]) { self.values = values }

    init(root: URL) {
        var map: [String: [String]] = [:]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if Self.skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "strings", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for match in Self.entryRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let k = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text) else { continue }
                    let value = String(text[v])
                    if !value.isEmpty { map[String(text[k]), default: []].append(value) }
                }
            }
        }
        for key in map.keys {
            var seen = Set<String>()
            map[key] = map[key]?.filter { seen.insert($0).inserted }
        }
        values = map
    }

    /// Other-language texts that stand for `label`. Exact value match first; otherwise the single best fuzzy key
    /// (shared non-Latin run of ≥3 chars, Latin words in the label/key earn a bonus). Empty when nothing is convincing.
    func aliases(for label: String) -> [String] {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return [] }

        let exactKeys = values.filter { $0.value.contains(label) }.map(\.key)
        if !exactKeys.isEmpty {
            return Self.unique(exactKeys.sorted().flatMap { values[$0] ?? [] }, excluding: label)
        }
        // Near-ties are all kept: "Shop注文履歴" is equally close to a generic "Shopping Order History" key and to the
        // screen's own title key, and only the live UI can tell which one is shown.
        let ranked = rankedKeys(for: label)
        guard let best = ranked.first else { return [] }
        return Self.unique(ranked.filter { best.score - $0.score <= 2 }.prefix(3).flatMap { values[$0.key] ?? [] }, excluding: label)
    }

    /// Best fuzzy key for a label together with its score (nil when no key shares a convincing fragment).
    func bestKey(for label: String) -> (key: String, score: Int)? { rankedKeys(for: label).first }

    func rankedKeys(for label: String) -> [(key: String, score: Int)] {
        let (latinWords, otherRuns) = Self.segments(of: label)
        var scored: [(key: String, score: Int)] = []
        for (key, vals) in values {
            var score = 0
            if otherRuns.isEmpty {
                score = vals.map { Self.commonLength(label, $0) }.max() ?? 0
                if score < 4 { continue }
            } else {
                let part = otherRuns.map { run in vals.map { Self.commonLength(run, $0) }.max() ?? 0 }.max() ?? 0
                if part < min(3, otherRuns.map(\.count).min() ?? 3) { continue }
                score = part * 2
                let haystack = ([key] + vals).joined(separator: " ").lowercased()
                if latinWords.contains(where: { haystack.contains($0.lowercased()) }) { score += 4 }
                else if !latinWords.isEmpty { score -= 3 }   // label has a Latin word ("Shop") this key does not mention
            }
            score -= (vals.map { abs($0.count - label.count) }.min() ?? 0) / 10
            scored.append((key, score))
        }
        return scored.sorted { ($0.score, $1.key) > ($1.score, $0.key) }
    }

    /// Keys whose localised text appears (quoted) in a source file's text — what that screen shows.
    func texts(referencedIn source: String, limit: Int = 60) -> [String] {
        // One pass over the file's string literals, then dictionary lookups — not one text scan per key.
        var literals = Set<String>()
        for match in Self.literalRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) { literals.insert(String(source[range])) }
        }
        var result: [String] = []
        for key in literals.sorted() { if let vals = values[key] { result += vals } }
        return Array(Self.unique(result, excluding: "").prefix(limit))
    }

    private static let literalRegex = try! NSRegularExpression(pattern: #""([A-Za-z0-9._-]{3,80})""#)

    // MARK: helpers

    private static func unique(_ texts: [String], excluding: String) -> [String] {
        var seen: Set<String> = [excluding]
        return texts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// (runs of Latin letters, runs of other letters) with ≥3 chars, e.g. "Shop注文履歴" → (["Shop"], ["注文履歴"]).
    static func segments(of text: String) -> (latin: [String], other: [String]) {
        var latinWords: [String] = [], otherRuns: [String] = []
        var run = "", runIsLatin = true
        func flush() {
            if run.count >= 3 { if runIsLatin { latinWords.append(run) } else { otherRuns.append(run) } }
            run = ""
        }
        for ch in text {
            let latin = ch.isASCII && ch.isLetter
            if !(ch.isLetter || ch.isNumber) || (latin != runIsLatin && !run.isEmpty) { flush() }
            if ch.isLetter || ch.isNumber { runIsLatin = latin; run.append(ch) }
        }
        flush()
        return (latinWords, otherRuns)
    }

    static func commonLength(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }
}
