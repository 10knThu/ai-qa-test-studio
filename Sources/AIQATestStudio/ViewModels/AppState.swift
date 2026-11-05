import Foundation
import Observation
import SwiftData

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, github, history, testCases, source, simulator, runner, flows, reports, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .github: return "GitHub Issue"
        case .history: return "History"
        case .testCases: return "Test Cases"
        case .source: return "Source Project"
        case .simulator: return "Simulator"
        case .runner: return "Test Runner"
        case .flows: return "Flows"
        case .reports: return "Reports"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .github: return "arrow.down.doc"
        case .history: return "clock.arrow.circlepath"
        case .testCases: return "checklist"
        case .source: return "hammer"
        case .simulator: return "iphone"
        case .runner: return "play.circle"
        case .flows: return "point.topleft.down.curvedto.point.bottomright.up"
        case .reports: return "chart.bar.doc.horizontal"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppState {
    let container: ModelContainer
    var selection: SidebarItem? = .dashboard

    let settings = SettingsViewModel()
    let simulator: SimulatorViewModel
    let source: SourceProjectViewModel
    let github: GitHubImportViewModel
    let testCases: TestCasesViewModel
    let runner: RunnerViewModel

    init() {
        container = PersistenceSchema.makeContainer()
        let context = container.mainContext
        let simulator = SimulatorViewModel()
        self.simulator = simulator
        source = SourceProjectViewModel(simulator: simulator, context: context)
        github = GitHubImportViewModel(context: context)
        testCases = TestCasesViewModel(context: context)
        runner = RunnerViewModel(context: context)
    }

    func bootstrap() async {
        await simulator.refresh()
        await source.restoreLastFolder()
        await settings.refreshOllama()
    }

    // MARK: AI analysis

    @discardableResult
    func analyze() async -> Bool {
        guard let snapshot = github.analysisSnapshot else {
            testCases.error = "Import a GitHub Issue first."
            return false
        }
        let ok = await testCases.generate(snapshot: snapshot, appContext: github.appContext, model: Prefs.ollamaModel,
                                          knownIdentifiers: source.knownIdentifiers)
        if ok { touchProject() }
        return ok
    }

    func quickGenerate() {
        guard let snapshot = github.analysisSnapshot else { return }
        selection = .testCases
        testCases.quickGenerate(snapshot: snapshot, knownIdentifiers: source.knownIdentifiers)
        touchProject()
    }

    func translatePlan() async {
        await testCases.translatePlan(model: Prefs.ollamaModel)
    }

    func analyzeAndShow() {
        selection = .testCases
        Task { await analyze() }
    }

    // MARK: Run orchestration

    /// Generates test cases when needed, builds & launches the app when needed, then executes.
    func generateAndRun() async {
        selection = .testCases
        if testCases.plan == nil || testCases.plan?.issueHash != github.snapshot?.contentHash {
            guard await analyze() else { return }
        }
        await run(cases: testCases.selectedCases)
    }

    private var isPreparingRun = false

    func run(cases: [PlannedCase]) async {
        guard !runner.isRunning, !isPreparingRun else { return }
        isPreparingRun = true
        defer { isPreparingRun = false }
        guard !cases.isEmpty else {
            runner.log.append("No test cases selected.", level: .warning)
            selection = .runner
            return
        }
        selection = .runner
        let issueURL = testCases.plan?.issueURL ?? github.snapshot?.htmlURL
        let ready = source.builtApp != nil && source.builtForIssue == issueURL
            && source.launchStage.isSucceeded && simulator.selected?.isBooted == true
        if !ready {
            guard source.sourceURL != nil else {
                runner.log.append("Select an iOS source folder in Source Project first.", level: .error)
                selection = .source
                return
            }
            runner.log.append("Preparing app (built once per issue): reuse or build → boot Simulator → install → launch…")
            guard await source.runPipeline(issueURL: issueURL) else {
                runner.log.append("Build/launch did not succeed — see Source Project for details. Test cases remain Not Run.", level: .error)
                return
            }
        }
        if runner.navigationGoal.isEmpty, let snapshot = github.analysisSnapshot {
            runner.navigationGoal = GoalDetector.detect(from: snapshot.checklist)
        }
        var extra = (hints: "", texts: [String](), paths: [String](), flow: FlowRecord?.none)
        let projectPath = source.sourceURL?.path ?? ""
        let scheme = source.selectedScheme
        if runner.autoNavigate, !runner.navigationGoal.isEmpty {
            let goal = runner.navigationGoal
            if let flow = runner.storedFlow(project: projectPath, scheme: scheme, goal: goal) {
                // Known route: no source reading now; the code is only analysed if replaying it fails.
                runner.log.append("↺ Dùng luồng đã học (\(flow.steps.joined(separator: " → ")), từ \(flow.sourceIssueURL), đã chạy đúng \(flow.successCount) lần) — không cần đọc source.", level: .success)
                extra = ("", flow.aliases + [flow.goal], [], flow)
            } else {
                runner.log.append("Chưa có luồng đã học — phân tích source để tìm luồng tới màn hình “\(goal)”…")
                let analysis = await source.navigationAnalysis(goal: goal)
                runner.log.append(analysis.hints.isEmpty ? "(không tìm thấy gợi ý trong source)" : analysis.hints)
                extra = (analysis.hints, analysis.goalTexts, analysis.pathTexts, nil)
            }
        }
        guard var info = makeRunInfo() else {
            runner.log.append("Missing issue, Simulator or built app — cannot start the run.", level: .error)
            return
        }
        info.navigationHints = extra.hints
        info.navigationGoalTexts = extra.texts
        info.navigationPathTexts = extra.paths
        info.navigationProject = projectPath
        info.navigationScheme = scheme
        info.storedFlow = extra.flow
        if extra.flow != nil, !runner.navigationGoal.isEmpty {
            let goal = runner.navigationGoal
            let runnerRef = runner
            info.navigationHintsLoader = { [weak source] in
                await MainActor.run { runnerRef.log.append("Luồng đã lưu hỏng — đọc source để khám phá lại…", level: .warning) }
                return await source?.navigationAnalysis(goal: goal).hints ?? ""
            }
        }
        await AppiumLauncher.ensureRunning(url: Prefs.appiumURL) { [runner] message in runner.log.append(message) }
        var cases = cases
        if let root = source.sourceURL {
            let index = await Task.detached(priority: .utility) { LocalizationIndex(root: root) }.value
            cases = LabelAliasEnricher.enrich(cases, index: index)
        }
        runner.start(cases: cases, info: info)
    }

    func makeRunInfo() -> RunInfo? {
        guard let device = simulator.selected, let app = source.builtApp, let plan = testCases.plan else { return nil }
        return RunInfo(issueURL: plan.issueURL, issueTitle: github.snapshot?.title ?? plan.issueURL,
                       issueRevision: github.revision, planVersion: plan.version, model: plan.model,
                       device: device, app: app, buildLogPath: source.lastBuildLogPath)
    }

    // MARK: History

    /// Starts a fresh import: clears the current issue + generated cases (saved history is untouched).
    func newIssue() {
        guard !runner.isRunning, !testCases.isGenerating else { return }
        github.reset()
        testCases.clear()
        selection = .github
    }

    /// Reopens a previously imported issue (from the local cache) and optionally one of its generated plans.
    func openFromHistory(_ record: GitHubIssueRecord, plan: TestPlanRecord?) {
        github.load(record)
        if let plan { testCases.load(plan) } else { testCases.clear() }
        selection = plan == nil ? .github : .testCases
    }

    // MARK: Recent projects

    func touchProject() {
        let context = container.mainContext
        let issueURL = github.snapshot?.htmlURL
        let sourcePath = source.sourceURL?.path
        let name = github.snapshot.map { "\($0.repo) #\($0.number)" } ?? source.sourceURL?.lastPathComponent ?? "Project"
        let projects = (try? context.fetch(FetchDescriptor<QAProject>())) ?? []
        let existing = projects.first { $0.issueURL == issueURL && issueURL != nil } ?? projects.first { $0.sourcePath == sourcePath && issueURL == nil }
        let project = existing ?? QAProject(name: name)
        if existing == nil { context.insert(project) }
        project.name = name
        project.issueURL = issueURL ?? project.issueURL
        project.sourcePath = sourcePath ?? project.sourcePath
        project.updatedAt = Date()
        try? context.save()
    }
}
