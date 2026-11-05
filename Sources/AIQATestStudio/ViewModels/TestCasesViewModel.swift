import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TestCasesViewModel {
    private let context: ModelContext
    fileprivate let planner = TestPlanGenerator()

    var plan: TestPlan?
    var selectedIDs: Set<String> = []
    var focusedID: String?
    var isGenerating = false
    var progress = ""
    var generationStartedAt: Date?
    let log = LogStore()
    var error: String?
    private var planRecord: TestPlanRecord?

    init(context: ModelContext) { self.context = context }

    var cases: [PlannedCase] { plan?.cases ?? [] }
    var originalCases: [PlannedCase] { cases.filter { $0.draft.category == .original } }
    var suggestedCases: [PlannedCase] { cases.filter { $0.draft.category == .suggested } }
    var selectedCases: [PlannedCase] { cases.filter { selectedIDs.contains($0.id) } }
    var focusedCase: PlannedCase? { cases.first { $0.id == focusedID } ?? cases.first }
    var casesWithMissingData: [PlannedCase] { cases.filter { !$0.missingTestData.isEmpty } }

    func generate(snapshot: IssueSnapshot, appContext: String, model: String, knownIdentifiers: Set<String>) async -> Bool {
        isGenerating = true
        error = nil
        log.clear()
        generationStartedAt = Date()
        defer { isGenerating = false; progress = "" }
        let ai = LocalAIService()
        do {
            var streamed: [TestCaseDraft] = []
            let drafts = try await ai.generate(snapshot: snapshot, appContext: appContext, model: model,
                                               knownIdentifiers: knownIdentifiers, progress: { [weak self] message in
                Task { @MainActor in self?.progress = message }
            }, onReset: { [weak self] in
                streamed = []
                self?.plan = nil
            }, onRollback: { [weak self] count in
                guard let self, count > 0 else { return }
                streamed.removeLast(min(count, streamed.count))
                self.plan = streamed.isEmpty ? nil : self.planner.generate(drafts: streamed, snapshot: snapshot, model: model, version: 0,
                                                                          knownIdentifiers: knownIdentifiers, fillMissing: false)
            }, onCase: { [weak self] draft in
                // Show each case as soon as the model finishes it (provisional numbering/readiness).
                guard let self else { return }
                streamed.append(draft)
                let provisional = self.planner.generate(drafts: streamed, snapshot: snapshot, model: model, version: 0,
                                                        knownIdentifiers: knownIdentifiers, fillMissing: false)
                self.plan = provisional
                self.selectedIDs = Set(provisional.cases.map(\.id))
                if self.focusedID == nil || !provisional.cases.contains(where: { $0.id == self.focusedID }) {
                    self.focusedID = provisional.cases.first?.id
                }
                self.log.append("✔ Test case #\(streamed.count): \(draft.title)", level: .success)
                self.progress = "Đã sinh \(streamed.count) test case… (model đang tiếp tục)"
            }, log: { [weak self] message in self?.log.append(message) })
            log.append("⑥ Dựng test plan thực thi và lưu local…")
            progress = "Building executable test plan…"
            install(drafts: drafts, snapshot: snapshot, model: model, knownIdentifiers: knownIdentifiers)
            return true
        } catch {
            self.error = error.userText
            log.append(error.userText, level: .error)
            return false
        }
    }

    /// Final plan from drafts: versioned, persisted, selected.
    private func install(drafts: [TestCaseDraft], snapshot: IssueSnapshot, model: String, knownIdentifiers: Set<String>) {
        let url = snapshot.htmlURL
        let previous = (try? context.fetch(FetchDescriptor<TestPlanRecord>(predicate: #Predicate { $0.issueURL == url }))) ?? []
        let version = (previous.map(\.version).max() ?? 0) + 1
        let newPlan = planner.generate(drafts: drafts, snapshot: snapshot, model: model, version: version, knownIdentifiers: knownIdentifiers)
        plan = newPlan
        selectedIDs = Set(newPlan.cases.map(\.id))
        focusedID = newPlan.cases.first?.id
        persistNewPlan(newPlan)
    }

    /// Instant, no AI: uses the author's own steps / expected results and quoted UI labels.
    func quickGenerate(snapshot: IssueSnapshot, knownIdentifiers: Set<String>) {
        error = nil
        log.clear()
        let drafts = QuickCaseBuilder.drafts(from: snapshot.checklist, goal: GoalDetector.detect(from: snapshot.checklist))
        guard !drafts.isEmpty else {
            error = "No checklist items selected. Tick at least one item on the GitHub Issue screen."
            return
        }
        install(drafts: drafts, snapshot: snapshot, model: "quick-rules", knownIdentifiers: knownIdentifiers)
        log.append("⚡ Tạo nhanh \(drafts.count) test case từ nguyên văn issue (không gọi AI).", level: .success)
    }

    /// Translates already-built cases to Vietnamese with the local model (small, separate calls).
    func translatePlan(model: String) async {
        guard let current = plan else { return }
        guard !model.isEmpty else { error = "Choose a local model in Settings first."; return }
        isGenerating = true
        error = nil
        log.clear()
        generationStartedAt = Date()
        defer { isGenerating = false; progress = "" }
        let ai = LocalAIService()
        let targets = current.cases.indices.filter { LocalAIService.needsTranslation(current.cases[$0].draft) }
        guard !targets.isEmpty else { log.append("Không có test case nào cần dịch.", level: .info); return }
        log.append("Dịch \(targets.count) test case sang tiếng Việt bằng \(model)…")
        var updated = current
        for start in stride(from: 0, to: targets.count, by: LocalAIService.batchSize) {
            if Task.isCancelled { break }
            let chunk = Array(targets[start..<min(start + LocalAIService.batchSize, targets.count)])
            progress = "Đang dịch \(start + 1)–\(start + chunk.count)/\(targets.count)…"
            let translated = await ai.translateToVietnamese(chunk.map { updated.cases[$0].draft }, model: model)
            for (position, index) in chunk.enumerated() {
                let draft = translated[position]
                updated.cases[index].draft = draft
                let offset = updated.cases[index].actions.count - draft.actions.count
                if offset >= 0 {
                    for action in draft.actions.indices { updated.cases[index].actions[action + offset].expectedOutcome = draft.actions[action].expectedOutcome }
                }
                log.append("✔ \(updated.cases[index].id): \(draft.title)", level: .success)
            }
            plan = updated
        }
        savePlanEdits()
    }

    // MARK: History

    func load(_ record: TestPlanRecord) {
        guard let loaded = try? GitHubImportViewModel.decoder.decode(TestPlan.self, from: record.planJSON) else {
            error = "This saved plan could not be read."
            return
        }
        plan = loaded
        planRecord = record
        selectedIDs = Set(loaded.cases.map(\.id))
        focusedID = loaded.cases.first?.id
        error = nil
    }

    func clear() {
        plan = nil; planRecord = nil; selectedIDs = []; focusedID = nil; error = nil
    }

    // MARK: Editing (review before execution)

    func update(_ id: String, _ change: (inout PlannedCase) -> Void) {
        guard var current = plan, let index = current.cases.firstIndex(where: { $0.id == id }) else { return }
        change(&current.cases[index])
        plan = current
        savePlanEdits()
    }

    func setTestData(caseID: String, name: String, value: String) {
        update(caseID) { planned in
            if let index = planned.draft.testData.firstIndex(where: { $0.name == name }) {
                planned.draft.testData[index].value = value
            }
        }
    }

    /// Edit from the editor: applies the change, then keeps ids / readiness / notes consistent.
    func edit(_ id: String, _ change: (inout PlannedCase) -> Void) {
        update(id) { planned in
            change(&planned)
            CaseEditing.normalize(&planned)
        }
    }

    func addCase() {
        guard var current = plan else { return }
        let created = CaseEditing.newCase(id: CaseEditing.nextID(in: current.cases))
        current.cases.append(created)
        plan = current
        selectedIDs.insert(created.id)
        focusedID = created.id
        savePlanEdits()
    }

    func duplicate(_ id: String) {
        guard var current = plan, let source = current.cases.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.draft.id = CaseEditing.nextID(in: current.cases)
        copy.draft.title += " (bản sao)"
        CaseEditing.normalize(&copy)
        current.cases.append(copy)
        plan = current
        selectedIDs.insert(copy.id)
        focusedID = copy.id
        savePlanEdits()
    }

    func delete(_ id: String) {
        guard var current = plan else { return }
        current.cases.removeAll { $0.id == id }
        plan = current
        selectedIDs.remove(id)
        if focusedID == id { focusedID = current.cases.first?.id }
        savePlanEdits()
    }

    /// Approves every selected case that is only waiting for review (cases missing test data stay blocked).
    @discardableResult
    func approveAllSelected() -> Int {
        guard var current = plan else { return 0 }
        var count = 0
        for index in current.cases.indices where selectedIDs.contains(current.cases[index].id)
            && current.cases[index].effectiveReadiness == .needsReview {
            current.cases[index].approved = true
            count += 1
        }
        plan = current
        if count > 0 { savePlanEdits() }
        return count
    }

    var pendingReviewCount: Int { selectedCases.filter { $0.effectiveReadiness == .needsReview }.count }

    func approve(_ id: String) { update(id) { $0.approved = true } }

    func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func selectAll(_ on: Bool) { selectedIDs = on ? Set(cases.map(\.id)) : [] }

    // MARK: Persistence

    private func persistNewPlan(_ plan: TestPlan) {
        let data = (try? GitHubImportViewModel.encoder.encode(plan)) ?? Data()
        let record = TestPlanRecord(issueURL: plan.issueURL, version: plan.version, issueHash: plan.issueHash,
                                    model: plan.model, planJSON: data)
        context.insert(record)
        planRecord = record
        for planned in plan.cases {
            let caseData = (try? GitHubImportViewModel.encoder.encode(planned)) ?? Data()
            context.insert(GeneratedTestCase(issueURL: plan.issueURL, caseID: planned.id, title: planned.draft.title,
                                             category: planned.draft.category.rawValue, planVersion: plan.version,
                                             plannedCaseJSON: caseData))
        }
        try? context.save()
    }

    private func savePlanEdits() {
        guard let plan, let planRecord else { return }
        planRecord.planJSON = (try? GitHubImportViewModel.encoder.encode(plan)) ?? planRecord.planJSON
        try? context.save()
    }
}
