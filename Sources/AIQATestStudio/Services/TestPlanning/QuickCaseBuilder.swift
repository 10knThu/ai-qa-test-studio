import Foundation

/// Builds test-case drafts WITHOUT an AI call from the issue author's own steps / expected results.
/// Actions come from quoted UI labels (「…」 “…” "…") next to tap / display words. Everything is flagged for review
/// because navigation to the screen under test cannot be inferred from text alone.
enum QuickCaseBuilder {
    private static let quoteRegex = try! NSRegularExpression(pattern: #"「([^」]+)」|“([^”]+)”|"([^"]+)""#)
    private static let tapWords = ["タップ", "押", "選択", "クリック", "切り替", "切替", "tap", "bấm", "nhấn", "chọn", "click", "press"]
    private static let showWords = ["表示", "hiển thị", "displayed", "shown", "visible"]
    private static let hiddenWords = ["非表示", "表示されない", "表示されません", "không hiển thị", "not displayed", "not shown", "hidden"]

    /// A quoted format description such as 「YYYY/M/D HH:mm〜HH:mm」 or 「JPY [金額]」 is not literal on-screen text.
    static func isFormatPlaceholder(_ label: String) -> Bool {
        ["YYYY", "HH:mm", "[", "]", "{", "}", "＜", "＞"].contains { label.contains($0) }
    }

    static func quoted(in text: String) -> [String] {
        quoteRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.first
        }
    }

    // MARK: Checks that can be verified on live data without knowing the exact values

    /// A check on content whose value is unknown in advance (price, date, quantity): the live UI must show text of that shape.
    private struct ShapeRule { let keywords: [String]; let regex: String; let description: String }
    private static let shapeRules: [ShapeRule] = [
        ShapeRule(keywords: ["金額", "JPY"], regex: #"(?s).*JPY ?[0-9][0-9,]*.*"#, description: "một số tiền dạng “JPY [金額]”"),
        ShapeRule(keywords: ["受取り日時", "受け取り日時", "日時"], regex: #"(?s).*[0-9]{4}/[0-9]{1,2}/[0-9]{1,2} [0-9]{1,2}:[0-9]{2}.*"#, description: "ngày giờ dạng “YYYY/M/D HH:mm”"),
        ShapeRule(keywords: ["数量"], regex: #"(?s).*(数量|數量|[Qq]uantity)[:：] ?[0-9]+.*"#, description: "số lượng dạng “数量: N”"),
    ]
    /// States that accessibility cannot expose, so a visibility check would claim more than it proves.
    private static let unverifiableWords = ["選択状態", "ハイライト", "highlight", "selected state"]
    private static let transitionWords = ["遷移", "移動", "chuyển"]

    static func drafts(from items: [ChecklistItem], goal: String = "") -> [TestCaseDraft] {
        items.map { item in
            let stepText = item.providedSteps ?? ""
            let expectedText = item.providedExpected ?? ""
            var actions: [ActionDraft] = []
            let mentionsTransition = transitionWords.contains { (expectedText + item.text).contains($0) }

            var tapped: [String] = []
            if tapWords.contains(where: { stepText.lowercased().contains($0) }) {
                for label in quoted(in: stepText) {
                    // Prove the control is on screen before tapping it (a tap that navigates away would hide it afterwards).
                    if !tapped.contains(label), mentionsTransition {
                        actions.append(ActionDraft(type: .assertVisible, target: Locator(strategy: .label, value: label), expectedOutcome: "「\(label)」 hiển thị trước khi bấm"))
                    }
                    actions.append(ActionDraft(type: .tap, target: Locator(strategy: .label, value: label), expectedOutcome: "「\(label)」"))
                    tapped.append(label)
                }
            }
            // Tap + 遷移: the screen under test must be gone afterwards (verifiable: its title is no longer on screen).
            if !tapped.isEmpty, mentionsTransition, !goal.isEmpty {
                actions.append(ActionDraft(type: .assertNotVisible, target: Locator(strategy: .label, value: goal),
                                           expectedOutcome: "Đã rời màn hình “\(goal)” sau khi bấm (遷移)"))
            }

            // No separate expected result: a title like 「X」が表示されることの確認 already states the check.
            let titleStatesCheck = expectedText.isEmpty && showWords.contains { item.text.contains($0) }
            let checkText = titleStatesCheck ? item.text : expectedText
            let hidden = hiddenWords.contains { checkText.lowercased().contains($0) }
            let unverifiable = unverifiableWords.contains { checkText.lowercased().contains($0) }
            var reviewNote: String?
            if unverifiable {
                reviewNote = "Kết quả mong đợi nói về trạng thái chọn/highlight — accessibility không lộ thông tin này nên không thể tự xác minh."
            } else {
                let literalLabels = quoted(in: checkText).filter { !isFormatPlaceholder($0) }
                for label in literalLabels where !(tapped.contains(label) && mentionsTransition && !hidden) {
                    actions.append(ActionDraft(type: hidden ? .assertNotVisible : .assertVisible,
                                               target: Locator(strategy: .label, value: label), expectedOutcome: checkText))
                }
                if literalLabels.isEmpty, !hidden {
                    let haystack = item.text + " " + checkText
                    if let rule = shapeRules.first(where: { rule in rule.keywords.contains { haystack.contains($0) } }) {
                        actions.append(ActionDraft(type: .assertVisible, target: Locator(strategy: .labelMatches, value: rule.regex),
                                                   expectedOutcome: "\(checkText.isEmpty ? item.text : checkText) — kiểm tra trên dữ liệu thật: màn hình có \(rule.description)"))
                    }
                }
            }

            let hasAuthorText = item.providedSteps != nil || item.providedExpected != nil
            // A case with a real assertion is safe to run: if an element is missing at run time it ends as Needs Review.
            let runnable = actions.contains { $0.type.isAssertion }
            return TestCaseDraft(
                id: "", title: item.text, description: item.section ?? "", category: .original, preconditions: [],
                steps: item.providedSteps.map { [$0] } ?? [item.text],
                testData: [],
                expectedResults: item.providedExpected.map { [$0] } ?? ["(issue chưa nêu kết quả mong đợi)"],
                priority: .medium, sourceChecklistRef: item.id, sourceRequirementRef: nil, readiness: runnable ? .ready : .needsReview,
                reviewReason: runnable ? "" : (reviewNote ?? (hasAuthorText
                    ? "Tạo nhanh bằng quy tắc từ nguyên văn issue (không dùng AI): kết quả mong đợi không có nhãn UI hay mẫu dữ liệu nào để tự kiểm tra."
                    : "Mục checklist không có bước / kết quả mong đợi rõ ràng.")),
                actions: actions)
        }
    }
}

/// Guesses the screen under test from the issue's own test items.
/// 1) a label introduced as a screen title (「画面タイトル「X」」)  2) the most frequent quoted label that is NOT a tab/segment.
enum GoalDetector {
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"(?:画面)?(?:タイトル|title|tiêu đề)[^「“"\n]{0,6}(?:「([^」]+)」|“([^”]+)”|"([^"]+)")"#, options: [.caseInsensitive])
    private static let tabSuffixes = ["タブ", "tab", "セグメント", "ボタン", "リンク", "バッジ"]

    static func detect(from items: [ChecklistItem]) -> String {
        let texts = items.map { [$0.text, $0.providedSteps ?? "", $0.providedExpected ?? ""].joined(separator: " ") }

        var titleVotes: [String: Int] = [:]
        for text in texts {
            for match in titleRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let label = (1...3).compactMap({ Range(match.range(at: $0), in: text).map { String(text[$0]) } }).first {
                    titleVotes[label, default: 0] += 1
                }
            }
        }
        if let title = titleVotes.max(by: { ($0.value, $0.key.count) < ($1.value, $1.key.count) })?.key { return title }

        var counts: [String: Int] = [:]
        for text in texts {
            for label in Set(QuickCaseBuilder.quoted(in: text)) where !isControlLabel(label, in: text) { counts[label, default: 0] += 1 }
        }
        return counts.filter { $0.value >= 2 }.max { ($0.value, $0.key.count) < ($1.value, $1.key.count) }?.key ?? ""
    }

    /// True when every mention of the label is directly followed by a control word (「現在の注文」タブ).
    private static func isControlLabel(_ label: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        var mentions = 0, asControl = 0
        for closer in ["」", "”", "\""] {
            search = text.startIndex..<text.endIndex
            while let range = text.range(of: label + closer, range: search) {
                mentions += 1
                let after = text[range.upperBound...].prefix(4).lowercased()
                if tabSuffixes.contains(where: { after.hasPrefix($0) }) { asControl += 1 }
                search = range.upperBound..<text.endIndex
            }
        }
        return mentions > 0 && asControl == mentions
    }
}
