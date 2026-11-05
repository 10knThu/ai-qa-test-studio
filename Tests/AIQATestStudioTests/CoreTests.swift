import XCTest
import SwiftData
@testable import AIQATestStudio

final class CoreTests: XCTestCase {

    func testIssueURLParsing() throws {
        let ref = try GitHubIssueService.parse("https://github.com/acme/app/issues/42")
        XCTAssertEqual(ref, GitHubIssueRef(owner: "acme", repo: "app", number: 42))
        XCTAssertThrowsError(try GitHubIssueService.parse("https://github.com/acme/app/pull/42"))
        XCTAssertThrowsError(try GitHubIssueService.parse("https://evil.com/acme/app/issues/1"))
        XCTAssertThrowsError(try GitHubIssueService.parse("not a url"))
        XCTAssertThrowsError(try GitHubIssueService.parse("https://github.com/acme/app/issues/abc"))
    }

    func testChecklistParsingIgnoresCodeFencesAndKeepsState() {
        let markdown = """
        ## Tasks
        - [ ] ログインできる
        - [x] Đăng xuất hoạt động
        ```
        - [ ] not a task
        ```
        ## Acceptance Criteria
        - Error is shown for a wrong password
        """
        let items = IssueMarkdownParser.checklist(from: markdown)
        XCTAssertEqual(items.map(\.text), ["ログインできる", "Đăng xuất hoạt động"])
        XCTAssertEqual(items.map(\.checked), [false, true])
        XCTAssertEqual(items.first?.section, "Tasks")
        let requirements = IssueMarkdownParser.requirements(from: markdown)
        XCTAssertEqual(requirements.map(\.text), ["Error is shown for a wrong password"])
        XCTAssertEqual(requirements.first?.kind, "acceptance")
    }

    func testRuntimeVersionParsing() {
        XCTAssertEqual(SimulatorService.iOSVersion(fromRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2"), "26.2")
        XCTAssertNil(SimulatorService.iOSVersion(fromRuntime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"))
    }

    func testPlaceholderSubstitution() {
        let result = TestPlanGenerator.substitute("user={{email}} pw={{password}}", data: ["email": "a@b.c"])
        XCTAssertEqual(result.text, "user=a@b.c pw={{password}}")
        XCTAssertEqual(result.missing, ["password"])
    }

    func testPlanGeneratorOrdersLocatorsAndFlagsMissingAssertions() {
        let snapshot = IssueSnapshot(owner: "o", repo: "r", number: 1, title: "t", body: "", state: "open", htmlURL: "https://github.com/o/r/issues/1",
                                     labels: [], updatedAt: Date(), fetchedAt: Date(), comments: [],
                                     checklist: [ChecklistItem(id: "CL-1", text: "Login", isChecked: false, section: nil, line: 1, source: "description", sourceURL: "")],
                                     requirements: [], contentHash: "h")
        let tap = ActionDraft(type: .tap, target: Locator(strategy: .label, value: "Login"),
                              fallbackTargets: [Locator(strategy: .accessibilityId, value: "loginButton")], expectedOutcome: "tap")
        let draft = TestCaseDraft(id: "x", title: "Login", description: "", category: .original, preconditions: [], steps: ["tap"],
                                  testData: [], expectedResults: ["ok"], priority: .high, sourceChecklistRef: "CL-1",
                                  sourceRequirementRef: nil, readiness: .ready, reviewReason: nil, actions: [tap])
        let plan = TestPlanGenerator().generate(drafts: [draft], snapshot: snapshot, model: "m", version: 1, knownIdentifiers: [])
        let planned = plan.cases[0]
        XCTAssertEqual(planned.id, "TC-001")
        XCTAssertEqual(planned.actions[0].type, .relaunchApp)               // isolation action inserted
        XCTAssertEqual(planned.actions[1].target?.strategy, .accessibilityId) // identifier preferred
        XCTAssertEqual(planned.readiness, .needsReview)                      // no assertion → cannot pass
        XCTAssertEqual(planned.actions.map(\.sourceTestCaseID), ["TC-001", "TC-001"])
    }

    func testMissingChecklistCoverageCreatesNeedsReviewCase() {
        let snapshot = IssueSnapshot(owner: "o", repo: "r", number: 1, title: "t", body: "", state: "open", htmlURL: "u",
                                     labels: [], updatedAt: Date(), fetchedAt: Date(), comments: [],
                                     checklist: [ChecklistItem(id: "CL-1", text: "Item", isChecked: true, section: nil, line: 1, source: "description", sourceURL: "")],
                                     requirements: [], contentHash: "h")
        let plan = TestPlanGenerator().generate(drafts: [], snapshot: snapshot, model: "m", version: 1, knownIdentifiers: [])
        XCTAssertEqual(plan.cases.count, 1)
        XCTAssertEqual(plan.cases[0].effectiveReadiness, .needsReview)
    }

    func testTestDataGatesReadiness() {
        var planned = PlannedCase(draft: TestCaseDraft(id: "TC-001", title: "t", description: "", category: .original, preconditions: [], steps: [],
                                                        testData: [TestDataItem(name: "email", description: "", value: nil)], expectedResults: [],
                                                        priority: .low, sourceChecklistRef: nil, sourceRequirementRef: nil, readiness: .ready,
                                                        reviewReason: nil, actions: []), actions: [], readiness: .ready, notes: [])
        XCTAssertEqual(planned.effectiveReadiness, .needsTestData)
        planned.draft.testData[0].value = "a@b.c"
        XCTAssertEqual(planned.effectiveReadiness, .ready)
    }

    func testStrictValidationRejectsUnknownReferences() {
        let snapshot = IssueSnapshot(owner: "o", repo: "r", number: 1, title: "t", body: "", state: "open", htmlURL: "u",
                                     labels: [], updatedAt: Date(), fetchedAt: Date(), comments: [], checklist: [], requirements: [], contentHash: "h")
        let bad = TestCaseDraft(id: "1", title: "t", description: "", category: .original, preconditions: [], steps: ["s"], testData: [],
                                expectedResults: ["e"], priority: .low, sourceChecklistRef: "CL-9", sourceRequirementRef: nil,
                                readiness: .ready, reviewReason: nil, actions: [ActionDraft(type: .tap)])
        let problems = LocalAIService.validate([bad], snapshot: snapshot)
        XCTAssertTrue(problems.contains { $0.contains("CL-9") })
    }

    func testSchemaRejectsUnknownActionType() {
        let json = #"{"testCases":[{"id":"1","title":"t","description":"","category":"original","preconditions":[],"steps":[],"testData":[],"expectedResults":[],"priority":"high","readiness":"ready","actions":[{"type":"runShell","expectedOutcome":""}]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AIResponse.self, from: Data(json.utf8)))
    }

    func testBuildFailureHints() {
        let error = XcodeBuildService.failure(exitCode: 65, lines: ["/x.swift:1:1: error: No such module 'Alamofire'", "Pods/Foo"])
        XCTAssertTrue(error.recovery?.contains("pod install") ?? false)
    }

    func testProcessRunnerCapturesOutputAndExitCode() async throws {
        let ok = try await ProcessRunner.run("/bin/echo", ["hello world"])
        XCTAssertEqual(ok.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
        let bad = try await ProcessRunner.run("/usr/bin/false", [])
        XCTAssertEqual(bad.exitCode, 1)
    }

    func testProcessRunnerCancellationTerminatesProcess() async {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testHTMLReportEscapesContent() {
        let doc = ReportDocument(generatedAt: Date(), issueURL: "u", issueTitle: "<script>alert(1)</script>", issueRevision: 1, planVersion: 1,
                                 model: "m", device: "d", osVersion: "26.2", appBundleID: "b", startedAt: Date(), finishedAt: nil,
                                 infrastructureProblem: nil, summary: [:], cases: [])
        let html = ReportExporter.html(for: doc)
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }
}

final class LanguageTests: XCTestCase {
    func testCJKRatioDetectsChineseProseButAllowsQuotedLabels() {
        XCTAssertGreaterThan(LocalAIService.cjkRatio("检查注单列表页面的标题是否正确显示"), 0.9)
        XCTAssertLessThan(LocalAIService.cjkRatio("Kiểm tra tiêu đề trang là “注文履歴” khi mở danh sách"), 0.25)
    }
}

final class StructuredItemTests: XCTestCase {
    func testJapaneseNumberedTestItemsWithStepsAndExpected() {
        let markdown = """
        テスト項目
        ①Mock API段階（デザイン反映＆Mock API実装済み）
        【基本表示】

        * 1. 画面タイトル「Shop注文履歴」が表示されることの確認
           * 手順: マイページから本画面を開く
           * 期待結果: タイトル「Shop注文履歴」が表示されること
        * 2. 「Shopを見る」リンクの表示・遷移確認
           * 手順: 「Shopを見る」をタップする
           * 期待結果: リンクが表示されること
        【空状態】
        * 13. 「現在の注文」0件時の確認
           * 手順: 0件のMockデータで開く
           * 期待結果: 文言が表示されること
        ②実API段階
        【実データ表示】
        * 1. 実データで分類されることの確認
           * 手順: 実ユーザーで開く
           * 期待結果: 正しいタブに表示されること
        """
        let items = IssueMarkdownParser.testItems(from: markdown)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].text, "画面タイトル「Shop注文履歴」が表示されることの確認")
        XCTAssertEqual(items[0].steps, "マイページから本画面を開く")
        XCTAssertEqual(items[0].expected, "タイトル「Shop注文履歴」が表示されること")
        XCTAssertTrue(items[0].section?.contains("①Mock API段階") ?? false)
        XCTAssertTrue(items[0].section?.contains("基本表示") ?? false)
        XCTAssertTrue(items[2].section?.contains("空状態") ?? false)
        XCTAssertTrue(items[3].section?.contains("②実API段階") ?? false)   // numbering restarted, still a separate item
    }

    func testEnglishAndVietnameseLabelsAndPlainNumberedListsWithoutLabelsAreIgnored() {
        let markdown = """
        1. Login works
           Steps: open app
           Expected: home is shown
        2. Just a numbered note without labels
        3. Đăng xuất
           Các bước: bấm đăng xuất
           Kết quả mong đợi: về màn đăng nhập
        """
        let items = IssueMarkdownParser.testItems(from: markdown)
        XCTAssertEqual(items.map(\.text), ["Login works", "Đăng xuất"])
        XCTAssertEqual(items[1].expected, "về màn đăng nhập")
    }
}

final class NormalizationTests: XCTestCase {
    func testStepNumberPrefixesAreStripped() {
        let draft = TestCaseDraft(id: "", title: "t", description: "", category: .original, preconditions: [], steps: ["1. 1. Mở app", "2) Bấm nút"],
                                  testData: [], expectedResults: ["ok"], priority: .low, sourceChecklistRef: nil, sourceRequirementRef: nil,
                                  readiness: .ready, reviewReason: nil, actions: [])
        XCTAssertEqual(LocalAIService.normalize([draft])[0].steps, ["Mở app", "Bấm nút"])
    }
    func testJapaneseDraftNeedsTranslation() {
        let draft = TestCaseDraft(id: "", title: "画面のタイトル確認", description: "", category: .original, preconditions: ["ログイン済み"], steps: ["画面を開く"],
                                  testData: [], expectedResults: ["表示される"], priority: .low, sourceChecklistRef: nil, sourceRequirementRef: nil,
                                  readiness: .ready, reviewReason: nil, actions: [])
        XCTAssertTrue(LocalAIService.needsTranslation(draft))
    }
}

final class RepairTests: XCTestCase {
    func testMissingChecklistRefIsRepairedByPosition() {
        func draft(_ ref: String?) -> TestCaseDraft {
            TestCaseDraft(id: "", title: "t", description: "", category: .original, preconditions: [], steps: ["s"], testData: [],
                          expectedResults: ["e"], priority: .low, sourceChecklistRef: ref, sourceRequirementRef: nil,
                          readiness: .ready, reviewReason: nil, actions: [])
        }
        let items = ["CL-4", "CL-5"].map { ChecklistItem(id: $0, text: $0, isChecked: false, section: nil, line: 1, source: "d", sourceURL: "") }
        let fixed = LocalAIService.repairOriginalRefs([draft(nil), draft("CL-99")], items: items)
        XCTAssertEqual(fixed.map(\.sourceChecklistRef), ["CL-4", "CL-5"])
    }
}

final class CheckboxItemTests: XCTestCase {
    func testCheckboxItemsKeepNestedStepsAndExpectedAndDropNumbering() {
        let markdown = """
        ### 【基本表示】
        - [ ] 1. 画面タイトル「Shop注文履歴」が表示されることの確認
          - 手順: マイページから本画面を開く
          - 期待結果: タイトル「Shop注文履歴」が表示されること
        - [x] 2. 「Shopを見る」リンクの確認
          - 手順: 「Shopを見る」をタップする
          - 期待結果: 「Shopを見る」が表示されること
        """
        let items = IssueMarkdownParser.checklist(from: markdown)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "画面タイトル「Shop注文履歴」が表示されることの確認")
        XCTAssertEqual(items[0].steps, "マイページから本画面を開く")
        XCTAssertEqual(items[0].expected, "タイトル「Shop注文履歴」が表示されること")
        XCTAssertEqual(items[1].checked, true)
    }

    func testQuickBuilderDerivesActionsFromQuotedLabels() {
        let item = ChecklistItem(id: "CL-2", text: "Link", isChecked: false, section: nil, line: 1, source: "d", sourceURL: "",
                                 providedSteps: "「Shopを見る」をタップする", providedExpected: "Shop TOPが表示され、「ホーム」が表示されること")
        let draft = QuickCaseBuilder.drafts(from: [item])[0]
        XCTAssertEqual(draft.actions.map(\.type), [.tap, .assertVisible])
        XCTAssertEqual(draft.actions[0].target?.value, "Shopを見る")
        XCTAssertEqual(draft.readiness, .ready, "a case with an assertion is runnable")
        XCTAssertEqual(draft.sourceChecklistRef, "CL-2")
        let bare = ChecklistItem(id: "CL-3", text: "No checks", isChecked: false, section: nil, line: 2, source: "d", sourceURL: "")
        XCTAssertEqual(QuickCaseBuilder.drafts(from: [bare])[0].readiness, .needsReview, "no assertion → needs review")
    }
}

@MainActor
final class FlowLibraryTests: XCTestCase {
    private func library() throws -> FlowLibrary {
        let container = try ModelContainer(for: Schema(PersistenceSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return FlowLibrary(context: container.mainContext)
    }

    func testLearnFindAndAliasMatch() throws {
        let lib = try library()
        lib.learn(projectPath: "/p", scheme: "Staging", goal: "Shop注文履歴", aliases: ["Shop Order History"],
                  steps: ["Account", "Orders"], issueURL: "u1")
        XCTAssertEqual(lib.find(projectPath: "/p", scheme: "Staging", goal: "shop order history")?.steps, ["Account", "Orders"])
        XCTAssertNil(lib.find(projectPath: "/p", scheme: "Other", goal: "Shop注文履歴"))
        XCTAssertNil(lib.find(projectPath: "/p", scheme: "Staging", goal: "Something else"))
    }

    func testStaleFlowIsNotReturnedAndRelearnReplaces() throws {
        let lib = try library()
        lib.learn(projectPath: "/p", scheme: "S", goal: "G", aliases: [], steps: ["a"], issueURL: "u")
        let record = try XCTUnwrap(lib.find(projectPath: "/p", scheme: "S", goal: "G"))
        lib.recordFailure(record)
        XCTAssertNil(lib.find(projectPath: "/p", scheme: "S", goal: "G"))
        lib.learn(projectPath: "/p", scheme: "S", goal: "G", aliases: [], steps: ["b"], issueURL: "u2")
        XCTAssertEqual(lib.find(projectPath: "/p", scheme: "S", goal: "G")?.steps, ["b"])
    }
}

final class CaseEditingTests: XCTestCase {
    func testNewCaseNeedsAssertionThenBecomesReady() {
        var planned = CaseEditing.newCase(id: "TC-007")
        XCTAssertEqual(planned.readiness, .needsReview)
        XCTAssertEqual(planned.actions.first?.id, "TC-007-A01")
        var assertion = CaseEditing.blankAction(.assertVisible, caseID: "TC-007")
        assertion.target = Locator(strategy: .label, value: "Shop Order History")
        planned.actions.append(assertion)
        CaseEditing.normalize(&planned)
        XCTAssertEqual(planned.readiness, .ready)
        XCTAssertEqual(planned.actions.map(\.id), ["TC-007-A01", "TC-007-A02"])
    }

    func testEmptyLocatorAndNextID() {
        var planned = CaseEditing.newCase(id: "TC-001")
        planned.actions.append(CaseEditing.blankAction(.tap, caseID: "TC-001"))
        CaseEditing.normalize(&planned)
        XCTAssertTrue(planned.notes.contains { $0.contains("locator") })
        XCTAssertEqual(CaseEditing.nextID(in: [planned]), "TC-002")
    }
}

final class QuickTitleCheckTests: XCTestCase {
    func testTitleWithQuotedLabelBecomesAssertion() {
        let item = ChecklistItem(id: "CL-2", text: "画面タイトル「Shop注文履歴」が表示されることの確認", isChecked: false, section: nil, line: 1, source: "d", sourceURL: "")
        let draft = QuickCaseBuilder.drafts(from: [item])[0]
        XCTAssertEqual(draft.actions.map(\.type), [.assertVisible])
        XCTAssertEqual(draft.actions[0].target?.value, "Shop注文履歴")
        XCTAssertEqual(draft.readiness, .ready)
    }

    func testTitleWithoutQuotedLabelStaysNeedsReview() {
        let item = ChecklistItem(id: "CL-3", text: "数量が正しく表示されることの確認", isChecked: false, section: nil, line: 1, source: "d", sourceURL: "")
        XCTAssertEqual(QuickCaseBuilder.drafts(from: [item])[0].readiness, .needsReview)
    }
}
