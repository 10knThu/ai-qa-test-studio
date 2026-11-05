import XCTest
@testable import AIQATestStudio

final class OrderHistoryIssueTests: XCTestCase {
    static func checklist() throws -> [ChecklistItem] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/shop-order-history-issue.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return IssueMarkdownParser.testItems(from: markdown).enumerated().map { index, raw in
            ChecklistItem(id: "CL-\(index + 1)", text: raw.text, isChecked: false, section: raw.section, line: raw.line,
                          source: "description", sourceURL: "", providedSteps: raw.steps, providedExpected: raw.expected)
        }
    }

    func testGoalIsScreenTitleNotTab() throws {
        let items = try Self.checklist()
        XCTAssertGreaterThanOrEqual(items.count, 8)
        XCTAssertEqual(GoalDetector.detect(from: items), "Shop注文履歴")
    }

    func testTabLabelAloneIsNeverTheGoal() {
        let items = (1...3).map { ChecklistItem(id: "CL-\($0)", text: "「現在の注文」タブを確認", isChecked: false, section: nil, line: $0,
                                                 source: "d", sourceURL: "", providedSteps: "「現在の注文」タブを開く", providedExpected: "「現在の注文」タブが表示される") }
        XCTAssertEqual(GoalDetector.detect(from: items), "")
    }

    func testDraftsAreVerifiableOnlyWhenTheyProveSomething() throws {
        let items = try Self.checklist()
        let drafts = QuickCaseBuilder.drafts(from: items, goal: "Shop注文履歴")
        func draft(_ n: Int) -> TestCaseDraft { drafts[n - 1] }
        // title shown
        XCTAssertEqual(draft(1).readiness, .ready)
        // link: visible → tap → screen title gone
        XCTAssertEqual(draft(2).actions.map(\.type), [.assertVisible, .tap, .assertNotVisible])
        // two tabs shown
        XCTAssertEqual(draft(3).actions.filter { $0.type == .assertVisible }.count, 2)
        // selected-state cannot be proved through accessibility → must stay Needs Review
        XCTAssertEqual(draft(4).readiness, .needsReview)
        // content shape checks use real live data
        XCTAssertTrue(draft(6).actions.contains { $0.target?.strategy == .labelMatches })
        XCTAssertTrue(draft(7).actions.contains { $0.target?.strategy == .labelMatches })
        XCTAssertTrue(draft(8).actions.contains { $0.target?.strategy == .labelMatches })
    }

    func testDateAndPriceRegexMatchRealCardText() throws {
        let card = "Pickup time: 2026/11/13 10:00〜20:00\nTotal quantity: 1\nTotal amount: JPY7,684"
        let items = try Self.checklist()
        let drafts = QuickCaseBuilder.drafts(from: items, goal: "Shop注文履歴")
        for n in [6, 7, 8] {
            let regex = try XCTUnwrap(drafts[n - 1].actions.first { $0.target?.strategy == .labelMatches }?.target?.value)
            XCTAssertNotNil(card.range(of: "^" + regex + "$", options: .regularExpression), "case \(n)")
        }
    }
}
