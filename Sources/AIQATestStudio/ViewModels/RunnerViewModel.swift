import Foundation
import Observation
import SwiftData

struct RunInfo {
    var issueURL: String
    var issueTitle: String
    var issueRevision: Int
    var planVersion: Int
    var model: String
    var device: SimulatorDevice
    var app: BuiltApp
    var buildLogPath: String?
    var navigationHints: String = ""
    var navigationGoalTexts: [String] = []
    var navigationPathTexts: [String] = []
    var navigationProject: String = ""
    var navigationScheme: String = ""
    var storedFlow: FlowRecord?
    var navigationHintsLoader: (@Sendable () async -> String)?
}

/// What the Test Runner shows about how the screen under test is reached.
struct NavigationInfo {
    var goal: String
    var path: [String]
    var origin: NavigationOrigin
}

@MainActor
@Observable
final class RunnerViewModel {
    private let context: ModelContext

    var statuses: [String: ExecutionStatus] = [:]
    var messages: [String: String] = [:]
    var durations: [String: TimeInterval] = [:]
    /// Per case: how it was run (route + every action + outcome). Saved with the run and in the report.
    var flowNotes: [String: String] = [:]
    var stepResults: [String: [StepOutcome]] = [:]
    /// Screenshots saved for each case while it ran (shown in the Test Runner so a Pass can be checked by eye).
    var evidenceImages: [String: [URL]] = [:]
    var runCases: [PlannedCase] = []

    var isRunning = false
    var total = 0
    var completed = 0
    var currentCaseID: String?
    var currentAction: TestAction?
    var currentActionIndex = 0
    var currentActionCount = 0
    var focusedID: String?
    var infrastructureProblem: String?
    var currentRun: TestRunRecord?
    var lastExportFolder: URL?
    /// Visible text of the screen under test (auto-detected from the issue, editable).
    var navigationGoal = ""
    var autoNavigate = true
    let log = LogStore()

    private var worker: Task<Void, Never>?
    private var lastInfo: RunInfo?
    private var activeFlow: FlowRecord?
    private var runInfo: RunInfo?
    var navigationInfo: NavigationInfo?
    private var caseRecords: [String: TestCaseRunRecord] = [:]
    private var stepStartTimes: [String: Date] = [:]

    init(context: ModelContext) { self.context = context }

    func storedFlow(project: String, scheme: String, goal: String) -> FlowRecord? {
        FlowLibrary(context: context).find(projectPath: project, scheme: scheme, goal: goal)
    }

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    var retryableCases: [PlannedCase] {
        runCases.filter { [.failed, .blocked, .cancelled].contains(statuses[$0.id] ?? .notRun) }
    }

    // MARK: Control

    func start(cases: [PlannedCase], info: RunInfo) {
        guard !isRunning, !cases.isEmpty else { return }
        lastInfo = info
        runInfo = info
        activeFlow = info.storedFlow
        navigationInfo = nil
        runCases = cases
        statuses = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, ExecutionStatus.notRun) })
        messages = [:]; durations = [:]; stepResults = [:]; evidenceImages = [:]; caseRecords = [:]; flowNotes = [:]
        total = cases.count; completed = 0
        currentCaseID = nil; currentAction = nil; infrastructureProblem = nil
        focusedID = cases.first?.id

        let run = TestRunRecord(issueURL: info.issueURL, issueTitle: info.issueTitle)
        run.issueRevision = info.issueRevision
        run.planVersion = info.planVersion
        run.model = info.model
        run.deviceName = info.device.name
        run.osVersion = info.device.osVersion
        run.appBundleID = info.app.bundleID
        run.appPath = info.app.appURL.path
        run.buildLogPath = info.buildLogPath
        context.insert(run)
        for planned in cases {
            let record = TestCaseRunRecord(caseID: planned.id, title: planned.draft.title, category: planned.draft.category.title)
            record.run = run
            context.insert(record)
            caseRecords[planned.id] = record
        }
        currentRun = run

        let evidenceDir = AppPaths.ensure(AppPaths.evidence.appendingPathComponent(run.id.uuidString, isDirectory: true))
        let logURL = AppPaths.logs.appendingPathComponent("run-\(run.id.uuidString).log")
        log.clear()
        log.startFile(logURL)
        run.runLogPath = logURL.path
        try? context.save()

        let model = Prefs.ollamaModel
        let config = ExecutionConfig(udid: info.device.udid, bundleID: info.app.bundleID, deviceName: info.device.name,
                                     osVersion: info.device.osVersion, appiumURL: Prefs.appiumURL,
                                     evidenceDirectory: evidenceDir, locatorModel: model.isEmpty ? nil : model,
                                     navigationGoal: autoNavigate ? navigationGoal.trimmingCharacters(in: .whitespaces) : "",
                                     navigationHints: info.navigationHints, navigationGoalTexts: info.navigationGoalTexts,
                                     navigationPathTexts: info.navigationPathTexts,
                                     cachedNavigationPath: info.storedFlow?.steps ?? [],
                                     navigationHintsLoader: info.navigationHintsLoader)
        var suggester: (@Sendable (String, String) async -> Locator?)?
        if !model.isEmpty {
            suggester = { source, description in
                await LocalAIService().suggestLocator(model: model, pageSource: source, elementDescription: description)
            }
        }
        skipController.reset()
        let service = TestExecutionService(locatorSuggester: suggester, skip: skipController)

        isRunning = true
        let (stream, continuation) = AsyncStream<ExecutionEvent>.makeStream()
        worker = Task.detached {
            await service.execute(cases: cases, config: config) { continuation.yield($0) }
            continuation.finish()
        }
        Task { [weak self] in
            for await event in stream { self?.handle(event) }
            self?.finishIfNeeded()
        }
    }

    let skipController = SkipController()

    /// Skips one case: the running case stops after its current step; a case that has not started is never started.
    func skip(_ caseID: String) {
        guard isRunning, statuses[caseID] != .passed, statuses[caseID] != .failed else { return }
        skipController.request(caseID)
        log.append("⏭ Bỏ qua \(caseID) theo yêu cầu.", level: .warning)
    }

    func skipCurrent() { if let id = currentCaseID { skip(id) } }

    func stop() {
        guard isRunning else { return }
        log.append("■ Stop requested — finishing the current step…", level: .warning)
        worker?.cancel()
    }

    func retryFailed() {
        guard let info = lastInfo, !isRunning else { return }
        start(cases: retryableCases, info: info)
    }

    // MARK: Events

    private func handle(_ event: ExecutionEvent) {
        switch event {
        case .runStarted(let count):
            log.append("▶ Run started — \(count) test case(s)")
        case .caseStarted(let id, let actions):
            statuses[id] = .running
            currentCaseID = id
            currentActionCount = actions
            focusedID = id
            caseRecords[id]?.startedAt = Date()
            caseRecords[id]?.status = .running
            log.append("━━ \(id) — \(runCases.first { $0.id == id }?.draft.title ?? "")")
            if let planned = runCases.first(where: { $0.id == id }) { log.append("  Luồng: " + flowDescription(for: planned)) }
        case .actionStarted(_, let action, let index):
            currentAction = action
            currentActionIndex = index
            log.append("  ▸ \(action.id)  \(action.summary)")
        case .log(let message, let level):
            log.append(message, level: level == .error ? .error : level == .warning ? .warning : level == .success ? .success : .info)
        case .actionFinished(let outcome):
            stepResults[outcome.caseID, default: []].append(outcome)
            let level: LogStore.Level = outcome.status == .passed ? .success : outcome.status == .failed ? .error : .warning
            log.append("    \(outcome.status.title): \(outcome.message)  (\(String(format: "%.1f", outcome.duration))s)", level: level)
            if let record = caseRecords[outcome.caseID] {
                let step = TestStepResult(index: outcome.index, actionID: outcome.action.id,
                                          actionType: outcome.action.type.rawValue, actionSummary: outcome.action.summary)
                step.status = outcome.status; step.expected = outcome.expected; step.actual = outcome.actual
                step.message = outcome.message; step.startedAt = outcome.startedAt; step.duration = outcome.duration
                step.locatorUsed = outcome.locatorUsed; step.aiSuggestedLocator = outcome.aiSuggestedLocator
                step.screenshotPath = outcome.screenshot?.path
                step.caseRun = record
                context.insert(step)
            }
        case .evidence(let caseID, let url, let kind):
            if kind == "screenshot" { evidenceImages[caseID, default: []].append(url) }
            if let record = caseRecords[caseID] {
                let evidence = EvidenceRecord(path: url.path, kind: kind)
                evidence.caseRun = record
                context.insert(evidence)
            }
        case .caseFinished(let outcome):
            statuses[outcome.caseID] = outcome.status
            messages[outcome.caseID] = outcome.message
            durations[outcome.caseID] = outcome.endedAt.timeIntervalSince(outcome.startedAt)
            completed += 1
            let note = flowNote(caseID: outcome.caseID, outcome: outcome)
            flowNotes[outcome.caseID] = note
            if let record = caseRecords[outcome.caseID] {
                record.flowNote = note
                record.status = outcome.status; record.message = outcome.message
                record.startedAt = outcome.startedAt; record.endedAt = outcome.endedAt
            }
            let level: LogStore.Level = outcome.status == .passed ? .success : outcome.status == .failed ? .error : .warning
            log.append("◼ \(outcome.caseID): \(outcome.status.title) — \(outcome.message)", level: level)
            try? context.save()
        case .navigationPath(let goal, let path, let origin):
            navigationInfo = NavigationInfo(goal: goal, path: path, origin: origin)
            let library = FlowLibrary(context: context)
            switch origin {
            case .stored:
                if let flow = activeFlow { library.recordSuccess(flow) }
            case .explored:
                if let info = runInfo, !info.navigationProject.isEmpty, !path.isEmpty {
                    library.learn(projectPath: info.navigationProject, scheme: info.navigationScheme, goal: goal,
                                  aliases: info.navigationGoalTexts, steps: path, issueURL: info.issueURL)
                    log.append("💾 Đã lưu luồng vào thư viện: \(path.joined(separator: " → ")) — các issue sau dùng lại, không cần đọc code.", level: .success)
                }
            case .alreadyThere: break
            }
        case .flowStale:
            if let flow = activeFlow { FlowLibrary(context: context).recordFailure(flow); activeFlow = nil }
        case .runFinished(let problem):
            infrastructureProblem = problem
            currentRun?.infrastructureProblem = problem
        }
    }

    /// Human-readable record of how a case ran.
    private func flowNote(caseID: String, outcome: CaseOutcome) -> String {
        var lines: [String] = []
        guard let planned = runCases.first(where: { $0.id == caseID }) else { return outcome.message }
        if let nav = navigationInfo {
            let route = nav.path.isEmpty ? "đã ở sẵn màn hình" : nav.path.map { "“\($0)”" }.joined(separator: " → ")
            lines.append("Điều hướng tới “\(nav.goal)”: \(route) — nguồn: \(nav.origin.title)")
        } else if navigationGoal.isEmpty || !autoNavigate {
            lines.append("Không tự điều hướng (không đặt màn hình đích).")
        } else {
            lines.append("Chưa điều hướng được tới “\(navigationGoal)”.")
        }
        let results = stepResults[caseID] ?? []
        if results.isEmpty { lines.append("Không có action nào được chạy.") }
        for (index, action) in planned.actions.enumerated() {
            if let done = results.first(where: { $0.action.id == action.id }) {
                let detail = done.status == .passed ? "" : " — \(done.message)"
                lines.append("\(index + 1). \(action.summary): \(done.status.title)\(detail)")
            } else if !results.isEmpty {
                lines.append("\(index + 1). \(action.summary): chưa chạy")
            }
        }
        lines.append("Kết quả: \(outcome.status.title) — \(outcome.message)")
        return lines.joined(separator: "\n")
    }

    /// One line: how this case is run — navigation route, then its own actions.
    func flowDescription(for planned: PlannedCase) -> String {
        var parts: [String] = []
        if let nav = navigationInfo, !nav.path.isEmpty { parts.append("điều hướng \(nav.path.joined(separator: " → "))") }
        parts += planned.actions.map(\.summary)
        return parts.joined(separator: " ▸ ")
    }

    private func finishIfNeeded() {
        isRunning = false
        currentAction = nil
        currentCaseID = nil
        worker = nil
        currentRun?.finishedAt = Date()
        // Anything that never reported is marked Cancelled (e.g. the task died unexpectedly).
        for (id, status) in statuses where status == .running || status == .notRun {
            statuses[id] = .cancelled
            caseRecords[id]?.status = .cancelled
        }
        let passed = statuses.values.filter { $0 == .passed }.count
        log.append("■ Run finished — \(passed)/\(total) passed.")
        log.flush()
        log.closeFile()
        try? context.save()
    }
}
