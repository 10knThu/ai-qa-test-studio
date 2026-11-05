import Foundation

/// Read-only static analysis of the iOS source: where is a screen (identified by a visible text such as its
/// title) defined, and which other screens / files open it? The result is a compact text that grounds the
/// navigation agent (live UI exploration) so it follows the app's real flow instead of guessing.
enum SourceNavigationAnalyzer {
    private static let skipped: Set<String> = ["Pods", "Carthage", ".build", "build", "DerivedData", "node_modules", "SourcePackages", ".git", "vendor"]

    private struct SourceFile {
        let path: String; let text: String; let isSwift: Bool
        /// Every identifier-like word in the file, built once, so "does this file mention type X" is a set lookup
        /// instead of a scan of the whole text (that scan made the analysis take minutes on a 5000-file project).
        let tokens: Set<String>
    }

    private static func tokenize(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        var current: [UInt8] = []
        func flush() { if current.count >= 3, let word = String(bytes: current, encoding: .utf8) { tokens.insert(word) }; current.removeAll(keepingCapacity: true) }
        for byte in text.utf8 {
            let isWord = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
            if isWord { current.append(byte) } else { flush() }
        }
        flush()
        return tokens
    }

    struct Analysis {
        var hints: String
        /// Texts that identify the screen when visible in the app: the goal itself plus its localisations found in the source.
        var goalTexts: [String]
        /// Texts shown by the screens that open the goal screen (e.g. the menu row "Shop") — used to rank what to tap.
        var pathTexts: [String] = []
    }

    /// longest common substring length
    private static func commonLength(_ a: String, _ b: String) -> Int {
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

    static func analyze(root: URL, goal: String) -> Analysis {
        let files = load(root)
        guard !goal.isEmpty, !files.isEmpty else { return Analysis(hints: "", goalTexts: [goal]) }

        // 1. Localisation: the issue text often comes from the design (e.g. "Shop注文履歴") and differs from the app
        // string ("買い物注文履歴" / "Shop Order History"). Find keys whose values resemble the goal in ANY language.
        let entryRegex = try? NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"([^"]*)"\s*;"#, options: .anchorsMatchLines)
        var values: [String: [String]] = [:]      // key -> all localised values
        for file in files where !file.isSwift {
            guard let entryRegex else { break }
            for match in entryRegex.matches(in: file.text, range: NSRange(file.text.startIndex..., in: file.text)) {
                guard let k = Range(match.range(at: 1), in: file.text), let v = Range(match.range(at: 2), in: file.text) else { continue }
                values[String(file.text[k]), default: []].append(String(file.text[v]))
            }
        }
        // Goal segments: runs of Latin letters ("Shop") and runs of other letters, e.g. CJK ("注文履歴").
        var latinWords: [String] = [], otherRuns: [String] = []
        var run = "", runIsLatin = true
        func flushRun() {
            if run.count >= 3 { if runIsLatin { latinWords.append(run) } else { otherRuns.append(run) } }
            run = ""
        }
        for ch in goal {
            let latin = ch.isASCII && ch.isLetter
            if !(ch.isLetter || ch.isNumber) || (latin != runIsLatin && !run.isEmpty) { flushRun() }
            if ch.isLetter || ch.isNumber { runIsLatin = latin; run.append(ch) }
        }
        flushRun()

        var scored: [(key: String, score: Int)] = []
        for (key, vals) in values {
            var score = 0
            if otherRuns.isEmpty {
                score = vals.map { commonLength(goal, $0) }.max() ?? 0
                if score < 4 { continue }
            } else {
                // Must contain the non-Latin part (e.g. 注文履歴) in some language…
                let part = otherRuns.map { segment in vals.map { commonLength(segment, $0) }.max() ?? 0 }.max() ?? 0
                if part < min(3, otherRuns.map(\.count).min() ?? 3) { continue }
                score = part * 2
                // …and the Latin words (Shop) in the key or a value earn a bonus.
                let haystack = ([key] + vals).joined(separator: " ").lowercased()
                if latinWords.contains(where: { haystack.contains($0.lowercased()) }) { score += 4 }
            }
            score -= (vals.map { abs($0.count - goal.count) }.min() ?? 0) / 10
            scored.append((key: key, score: score))
        }
        // Only the best key (and exact ties): extra keys such as the section header "Order History" would make the
        // agent believe it already reached the goal while still on the menu.
        let sortedKeys = scored.sorted { ($0.score, $1.key) > ($1.score, $0.key) }
        let ranked = sortedKeys.first.map { top in Array(sortedKeys.prefix { $0.score == top.score }.prefix(2)) } ?? []

        var needles: Set<String> = [goal]
        var goalTexts: [String] = [goal]
        var lines: [String] = []
        for entry in ranked {
            needles.insert("\"\(entry.key)\""); needles.insert(camelCase(entry.key))
            let texts = Array(Set(values[entry.key] ?? []))
            goalTexts += texts
            lines.append("Localisation key `\(entry.key)` = " + texts.prefix(4).map { "“\($0)”" }.joined(separator: " / "))
        }

        // 2. Files that show the goal text / those keys, and the screen types declared there.
        let seeds = files.filter { file in file.isSwift && needles.contains { needle in file.text.contains(needle) } }
        guard !seeds.isEmpty else {
            return Analysis(hints: "No source file referencing “\(goal)” (or a similar localised string) was found — the screen may not exist in this checkout/branch.",
                            goalTexts: goalTexts)
        }
        let seedSummary: [String] = seeds.prefix(6).map { (file: SourceFile) -> String in
            "\(file.path) (types: \(types(in: file.text).prefix(3).joined(separator: ", ")))"
        }
        lines.append("Screen text appears in: " + seedSummary.joined(separator: "; "))

        // 3. Walk upwards: which files reference those screen types (push / present / NavigationLink / tab)?
        var frontier: [String] = seeds.prefix(6).flatMap { (file: SourceFile) -> [String] in types(in: file.text) }
        var visitedFiles = Set(seeds.map { (file: SourceFile) -> String in file.path })
        var orphans: [String] = []
        var pathTexts: [String] = []
        let localization = LocalizationIndex(values: values)
        for hop in 1...3 {
            var next: [String] = []
            for type in Set(frontier).sorted().prefix(16) {
                let users = files.filter { (file: SourceFile) -> Bool in file.isSwift && !visitedFiles.contains(file.path) && file.tokens.contains(type) }
                if users.isEmpty && hop == 1 { orphans.append(type) }
                for user in users.prefix(3) {
                    visitedFiles.insert(user.path)
                    pathTexts += localization.texts(referencedIn: user.text, limit: 400)
                    // Lazy: stop after the first two usages instead of testing every line of a huge view file.
                    let usageLines = user.text.split(separator: "\n", omittingEmptySubsequences: true).lazy
                        .filter { (line: Substring) -> Bool in line.contains(type) && containsWord(String(line), type) }
                        .prefix(2).map { String($0) }
                    let usage = usageLines.map { (line: String) -> String in String(line.trimmingCharacters(in: CharacterSet.whitespaces).prefix(140)) }.joined(separator: " ⏎ ")
                    let ids = identifiers(in: user.text).prefix(8).joined(separator: ", ")
                    let root = ["UITabBarController", "TabView", "UITabBar"].contains { user.text.contains($0) } ? " [tab bar / root]" : ""
                    lines.append("↑ hop \(hop): \(type) is opened from \(user.path)\(root): `\(usage)`" + (ids.isEmpty ? "" : " — identifiers there: \(ids)"))
                    next += types(in: user.text)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        if !orphans.isEmpty {
            lines.append("⚠︎ Not referenced by any other file (no entry point found — maybe not wired into navigation, feature-flagged or preview-only): " + orphans.joined(separator: ", "))
        }
        var seen = Set<String>()
        var seenPath = Set<String>(goalTexts)
        return Analysis(hints: String(lines.joined(separator: "\n").prefix(3200)), goalTexts: goalTexts.filter { !$0.isEmpty && seen.insert($0).inserted },
                        pathTexts: pathTexts.filter { !$0.isEmpty && seenPath.insert($0).inserted })
    }

    static func hints(root: URL, goal: String) -> String { analyze(root: root, goal: goal).hints }

    // MARK: helpers

    private static func load(_ root: URL) -> [SourceFile] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [SourceFile] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard ["swift", "m", "mm", "strings"].contains(url.pathExtension), result.count < 5000,
                  let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count < 600_000 else { continue }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isSwift = url.pathExtension != "strings"
            result.append(SourceFile(path: relative, text: text, isSwift: isSwift, tokens: isSwift ? tokenize(text) : []))
        }
        return result
    }

    private static let typeRegex = try! NSRegularExpression(pattern: #"\b(?:class|struct)\s+([A-Z][A-Za-z0-9_]{3,})"#)
    private static let identifierRegex = try! NSRegularExpression(pattern: #"accessibilityIdentifier\s*(?:\(\s*|=\s*)"([^"\n]{1,60})""#)

    private static func types(in text: String) -> [String] {
        let regex = typeRegex
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func identifiers(in text: String) -> [String] {
        let regex = identifierRegex
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: word, range: search) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            if !(before.isLetter || before.isNumber || before == "_") && !(after.isLetter || after.isNumber || after == "_") { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func camelCase(_ key: String) -> String {
        let parts = key.split(whereSeparator: { "_-. ".contains($0) }).map(String.init)
        guard let first = parts.first else { return key }
        return first.lowercased() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
