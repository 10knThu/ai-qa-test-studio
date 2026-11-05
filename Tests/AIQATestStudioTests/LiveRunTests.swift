import XCTest
@testable import AIQATestStudio

/// End-to-end against a REAL Simulator + Appium (no AI model). Opt-in:
///   AIQA_LIVE=1 AIQA_TEST_PROJECT=/path/to/ios AIQA_UDID=<udid> AIQA_BUNDLE=<id> AIQA_EVIDENCE=/tmp/dir swift test --filter LiveRunTests
final class LiveRunTests: XCTestCase {
    func testShopOrderHistoryEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["AIQA_LIVE"] == "1", "opt-in live test")
        let project = try XCTUnwrap(env["AIQA_TEST_PROJECT"])
        let udid = try XCTUnwrap(env["AIQA_UDID"]), bundle = try XCTUnwrap(env["AIQA_BUNDLE"])
        let evidence = URL(fileURLWithPath: env["AIQA_EVIDENCE"] ?? NSTemporaryDirectory()).appendingPathComponent("evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)

        let items = try OrderHistoryIssueTests.checklist()
        let goal = GoalDetector.detect(from: items)
        let analysis = SourceNavigationAnalyzer.analyze(root: URL(fileURLWithPath: project), goal: goal)
        let index = LocalizationIndex(root: URL(fileURLWithPath: project))
        let snapshot = IssueSnapshot(owner: "o", repo: "r", number: 1, title: "t", body: "", state: "open", htmlURL: "u", labels: [],
                                     updatedAt: Date(), fetchedAt: Date(), comments: [], checklist: items, requirements: [], contentHash: "h")
        let plan = TestPlanGenerator().generate(drafts: QuickCaseBuilder.drafts(from: items, goal: goal), snapshot: snapshot, model: "none",
                                                version: 1, knownIdentifiers: [], fillMissing: true)
        let cases = LabelAliasEnricher.enrich(plan.cases, index: index)

        let config = ExecutionConfig(udid: udid, bundleID: bundle, deviceName: "iPhone 17 Pro", osVersion: "26.2",
                                     appiumURL: URL(string: "http://127.0.0.1:4723")!, evidenceDirectory: evidence, locatorModel: nil,
                                     navigationGoal: goal, navigationHints: analysis.hints, navigationGoalTexts: analysis.goalTexts,
                                     navigationPathTexts: analysis.pathTexts)
        final class Box: @unchecked Sendable { var lines: [String] = []; var outcomes: [CaseOutcome] = []; var evidence: [String: [URL]] = [:] }
        let box = Box()
        await TestExecutionService().execute(cases: cases, config: config) { event in
            switch event {
            case .log(let text, _): box.lines.append(text)
            case .caseFinished(let outcome): box.outcomes.append(outcome)
            case .evidence(let id, let url, _): box.evidence[id, default: []].append(url)
            default: break
            }
        }
        var report = "goal=\(goal)\n" + box.lines.joined(separator: "\n") + "\n\n"
        for outcome in box.outcomes {
            report += "\(outcome.caseID) \(outcome.status.rawValue) assertions=\(outcome.assertionsExecuted) evidence=\(box.evidence[outcome.caseID]?.map(\.lastPathComponent) ?? []) — \(outcome.message)\n"
        }
        try report.write(to: evidence.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)
        for outcome in box.outcomes where outcome.status == .passed {
            XCTAssertFalse((box.evidence[outcome.caseID] ?? []).isEmpty, "\(outcome.caseID) passed without an evidence screenshot")
        }
        XCTAssertTrue(box.outcomes.contains { $0.status == .passed }, "navigation + cases should pass at least one case")
    }
}
