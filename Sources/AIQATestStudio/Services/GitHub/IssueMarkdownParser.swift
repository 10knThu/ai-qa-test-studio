import Foundation

/// Parses Markdown checklists and requirement-like sections. Works for English, Vietnamese and Japanese headings.
enum IssueMarkdownParser {
    struct RawChecklist { var text: String; var checked: Bool; var section: String?; var line: Int; var steps: String? = nil; var expected: String? = nil }
    struct RawRequirement { var text: String; var section: String; var kind: String }

    private static let checklistRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+\[( |x|X)\]\s+(.+?)\s*$"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(?!\[[ xX]\])(.+?)\s*$"#)
    private static let headingRegex = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#)

    private static let kinds: [(kind: String, keywords: [String])] = [
        ("acceptance", ["acceptance", "criteria", "tiêu chí", "tieu chi", "受け入れ", "受入", "完了条件", "合格"]),
        ("requirement", ["requirement", "spec", "yêu cầu", "yeu cau", "要件", "仕様", "要求"]),
        ("expectation", ["expected", "expectation", "test", "verify", "kỳ vọng", "ky vong", "kết quả mong đợi", "期待", "確認", "テスト", "動作"]),
    ]

    static func kind(forHeading heading: String) -> String? {
        let lower = heading.lowercased()
        return kinds.first { entry in entry.keywords.contains { lower.contains($0) } }?.kind
    }

    private static func capture(_ regex: NSRegularExpression, _ line: String, group: Int) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), let r = Range(match.range(at: group), in: line) else { return nil }
        return String(line[r])
    }

    /// Iterates non-code lines with their nearest heading.
    private static func scan(_ markdown: String, _ body: (_ line: String, _ number: Int, _ heading: String?) -> Void) {
        var inFence = false
        var heading: String?
        for (offset, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if let h = capture(headingRegex, raw, group: 1) { heading = h; continue }
            body(raw, offset + 1, heading)
        }
    }

    static func stripNumbering(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while let range = result.range(of: #"^\d+\s*[.)．]\s*"#, options: .regularExpression) { result.removeSubrange(range) }
        return result
    }

    /// Checkbox items. Indented 手順 / 期待結果 (Steps / Expected / Các bước / Kết quả…) lines below an item belong to it.
    static func checklist(from markdown: String) -> [RawChecklist] {
        var items: [RawChecklist] = []
        scan(markdown) { line, number, heading in
            let range = NSRange(line.startIndex..., in: line)
            if let match = checklistRegex.firstMatch(in: line, range: range),
               let stateRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                items.append(RawChecklist(text: stripNumbering(String(line[textRange])), checked: line[stateRange] != " ",
                                          section: heading, line: number))
                return
            }
            guard !items.isEmpty else { return }
            var content = line.trimmingCharacters(in: .whitespaces)
            if let prefix = bulletPrefixRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)).flatMap({ Range($0.range, in: content) }) {
                content = String(content[prefix.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            let last = items.count - 1
            if let steps = labelValue(content, labels: stepLabels) {
                items[last].steps = [items[last].steps, steps].compactMap { $0 }.joined(separator: " ")
            } else if let expected = labelValue(content, labels: expectedLabels) {
                items[last].expected = [items[last].expected, expected].compactMap { $0 }.joined(separator: " ")
            }
        }
        return items
    }

    // MARK: Structured test items ("1. title / 手順: … / 期待結果: …")

    private static let numberedRegex = try! NSRegularExpression(pattern: #"^\d+\s*[.)．]\s*(.+)$"#)
    private static let bulletPrefixRegex = try! NSRegularExpression(pattern: #"^(?:[-*+•]\s+)+"#)
    private static let stepLabels = ["手順", "操作手順", "steps", "step", "các bước", "bước thực hiện", "cách thực hiện"]
    private static let expectedLabels = ["期待結果", "期待値", "期待される結果", "expected result", "expected", "kết quả mong đợi", "kết quả"]
    private static let circledDigits = Set("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")

    private static func labelValue(_ content: String, labels: [String]) -> String? {
        let lower = content.lowercased()
        for label in labels where lower.hasPrefix(label) {
            let rest = content.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            if let first = rest.first, first == ":" || first == "：" {
                return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Test items written as numbered entries followed by steps / expected-result lines (EN / VI / JA labels).
    /// Phase headers (①Mock API段階…) and 【category】 headers become the item's section.
    static func testItems(from markdown: String) -> [RawChecklist] {
        var items: [RawChecklist] = []
        var current: RawChecklist?
        var phase: String?
        var category: String?
        var inFence = false

        func flush() {
            if let item = current, item.steps != nil || item.expected != nil { items.append(item) }
            current = nil
        }
        func section() -> String? {
            let parts = [phase, category].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " › ")
        }

        for (offset, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            var content = raw.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") || content.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || content.isEmpty { continue }
            if let range = bulletPrefixRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)).flatMap({ Range($0.range, in: content) }) {
                content = String(content[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if content.isEmpty { continue }

            if let steps = labelValue(content, labels: stepLabels) {
                if var item = current { item.steps = [item.steps, steps].compactMap { $0 }.joined(separator: " "); current = item }
            } else if let expected = labelValue(content, labels: expectedLabels) {
                if var item = current { item.expected = [item.expected, expected].compactMap { $0 }.joined(separator: " "); current = item }
            } else if let title = capture(numberedRegex, content, group: 1) {
                flush()
                current = RawChecklist(text: title, checked: false, section: section(), line: offset + 1)
            } else if content.hasPrefix("【"), content.hasSuffix("】") {
                flush(); category = String(content.dropFirst().dropLast())
            } else if let first = content.first, circledDigits.contains(first) {
                flush(); phase = content; category = nil
            } else if let heading = capture(headingRegex, content, group: 1) {
                flush(); phase = heading; category = nil
            }
        }
        flush()
        return items
    }

    /// Bullets / lines under acceptance-criteria style headings (excluding checklist items, which are handled separately).
    static func requirements(from markdown: String) -> [RawRequirement] {
        var results: [RawRequirement] = []
        scan(markdown) { line, _, heading in
            guard let heading, let kind = kind(forHeading: heading) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if let bullet = capture(bulletRegex, line, group: 1) {
                results.append(RawRequirement(text: bullet, section: heading, kind: kind))
            } else if capture(checklistRegex, line, group: 2) == nil, trimmed.count > 3, !trimmed.hasPrefix("<") {
                results.append(RawRequirement(text: trimmed, section: heading, kind: kind))
            }
        }
        return results
    }
}
