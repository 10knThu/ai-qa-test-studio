import XCTest
@testable import AIQATestStudio

/// Page sources captured from the real app (Appium /source) on the Simulator.
final class NavigationFixtureTests: XCTestCase {
    private let goals = ["Shop注文履歴", "買い物注文履歴", "Shop Order History"]

    private func fixture(_ name: String) throws -> [UIElementInfo] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).xml")
        return UIHierarchyParser.parse(try String(contentsOf: url, encoding: .utf8))
    }

    func testMyAccountMenuIsNotTheGoalEvenThoughItsHeaderSaysOrderHistory() throws {
        XCTAssertFalse(UIHierarchyParser.goalReached(try fixture("my_account"), goals: goals))
    }

    func testShopOrderHistoryIsRecognised() throws {
        XCTAssertTrue(UIHierarchyParser.goalReached(try fixture("shop_current"), goals: goals))
    }

    func testMenuRowTextInsideACellIsATapCandidate() throws {
        let keys = UIHierarchyParser.explorationCandidates(try fixture("my_account")).map(\.key)
        XCTAssertTrue(keys.contains("Shop"), "\(keys)")
        XCTAssertTrue(keys.contains("Account"), "tab bar button")
        XCTAssertFalse(keys.contains("2"), "badge counts are not targets")
    }

    func testDestructiveOrLeavingControlsAreNeverCandidates() throws {
        for text in ["Sign Out", "ログアウト", "Delete account", "Cancel order", "Show pickup QR code", "Back"] {
            XCTAssertTrue(UIHierarchyParser.isDenied(text), text)
        }
        XCTAssertFalse(UIHierarchyParser.isDenied("Shop"))
    }

    func testSourceAnalysisKeepsOnlyTheGoalKeyAndRanksTheMenuRow() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIQA_TEST_PROJECT"] ?? "")
        try XCTSkipIf(ProcessInfo.processInfo.environment["AIQA_TEST_PROJECT"] == nil, "set AIQA_TEST_PROJECT to the iOS source")
        let analysis = SourceNavigationAnalyzer.analyze(root: root, goal: "Shop注文履歴")
        XCTAssertTrue(analysis.goalTexts.contains("Shop Order History"), "\(analysis.goalTexts)")
        XCTAssertFalse(analysis.goalTexts.contains("Order History"), "section header would end exploration early: \(analysis.goalTexts)")
        XCTAssertTrue(analysis.pathTexts.contains("Shop"), "menu row text should rank first: \(analysis.pathTexts.prefix(20))")
    }
}
