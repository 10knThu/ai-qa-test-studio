import SwiftUI

struct TestCasesView: View {
    @Environment(AppState.self) private var app
    @State private var editing = false

    var body: some View {
        let vm = app.testCases
        VStack(spacing: 0) {
            if vm.isGenerating {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(vm.progress.isEmpty ? "Generating…" : vm.progress)
                        Spacer()
                        if let started = vm.generationStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("Đã chờ \(formatDuration(context.date.timeIntervalSince(started)))")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LogView(log: vm.log, minHeight: 140).frame(height: 160)
                }
                .padding(10).background(.blue.opacity(0.08))
            }
            if let error = vm.error { ErrorBanner(text: error).padding([.horizontal, .top], 16) }

            if vm.cases.isEmpty && !vm.isGenerating && vm.plan == nil {
                ContentUnavailableView("No test cases yet", systemImage: "checklist",
                                       description: Text("Import a GitHub Issue, then choose “Analyze with Local AI”."))
            } else {
                HSplitView {
                    List(selection: Binding(get: { vm.focusedID }, set: { vm.focusedID = $0 })) {
                        if !vm.originalCases.isEmpty {
                            Section("Original — from issue checklist (\(vm.originalCases.count))") {
                                ForEach(vm.originalCases) { row($0) }
                            }
                        }
                        if !vm.suggestedCases.isEmpty {
                            Section("AI Suggested — from requirements (\(vm.suggestedCases.count))") {
                                ForEach(vm.suggestedCases) { row($0) }
                            }
                        }
                    }
                    .frame(minWidth: 380, idealWidth: 440)
                    detail
                        .frame(minWidth: 420)
                }
            }
            Divider()
            toolbar
        }
        .navigationTitle("Generated Test Cases")
        .task(id: app.testCases.cases.map(\.id)) { TranslationStore.shared.request(cases: app.testCases.cases) }
    }

    private func row(_ planned: PlannedCase) -> some View {
        let vm = app.testCases
        return HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { vm.selectedIDs.contains(planned.id) }, set: { _ in vm.toggle(planned.id) }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(planned.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    readinessTag(planned.effectiveReadiness)
                    Text(planned.draft.priority.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                }
                Text(vi(planned.draft.title)).lineLimit(2).help(planned.draft.title)
            }
        }
        .tag(planned.id)
    }

    private func readinessTag(_ readiness: Readiness) -> some View {
        let color: Color = readiness == .ready ? .green : readiness == .needsReview ? .orange : .red
        return Text(readiness.title).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    @ViewBuilder
    private var detail: some View {
        if let planned = app.testCases.focusedCase {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Button { app.testCases.duplicate(planned.id) } label: { Label("Nhân bản", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { app.testCases.delete(planned.id) } label: { Label("Xoá", systemImage: "trash") }
                        Button { editing.toggle() } label: { Label(editing ? "Xong" : "Chỉnh sửa", systemImage: editing ? "checkmark" : "pencil") }
                            .buttonStyle(.borderedProminent)
                    }
                    if editing {
                        CaseEditorView(planned: planned).id(planned.id)
                    } else {
                    Text(vi(planned.draft.title)).font(.title3.bold()).textSelection(.enabled).help(planned.draft.title)
                    HStack {
                        readinessTag(planned.effectiveReadiness)
                        Text(planned.draft.category.title).font(.caption)
                        if let ref = planned.draft.sourceChecklistRef { Text("Checklist \(ref)").font(.caption.monospaced()) }
                        if let ref = planned.draft.sourceRequirementRef { Text("Requirement \(ref)").font(.caption.monospaced()) }
                    }
                    Text(vi(planned.draft.description)).textSelection(.enabled)
                    section("Preconditions", planned.draft.preconditions.map { vi($0) })
                    section("Steps", planned.draft.steps.map { vi($0) }, numbered: true)
                    section("Expected results", planned.draft.expectedResults.map { vi($0) })

                    if !planned.notes.isEmpty {
                        InfoBanner(text: planned.notes.joined(separator: "\n"))
                    }
                    if !planned.draft.testData.isEmpty { testData(planned) }

                    if planned.effectiveReadiness == .needsReview {
                        Button("Approve for automation anyway") { app.testCases.approve(planned.id) }
                    }

                    Text("Executable actions").font(.headline)
                    ForEach(planned.actions) { action in
                        VStack(alignment: .leading) {
                            Text("\(action.id)  \(action.summary)").font(.caption.monospaced()).textSelection(.enabled)
                            if !action.expectedOutcome.isEmpty {
                                Text("→ \(action.expectedOutcome)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a test case").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ title: String, _ items: [String], numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !items.isEmpty {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(numbered ? "\(index + 1). \(item)" : "• \(item)").textSelection(.enabled)
                }
            }
        }
    }

    private func testData(_ planned: PlannedCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test data").font(.headline)
            ForEach(planned.draft.testData) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name).font(.body.monospaced())
                        Text(item.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField(item.isMissing ? "Required — enter value" : "Value", text: Binding(
                        get: { item.value ?? "" },
                        set: { app.testCases.setTestData(caseID: planned.id, name: item.name, value: $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            if !planned.missingTestData.isEmpty {
                Text("Missing: \(planned.missingTestData.map(\.name).joined(separator: ", ")) — this case stays Blocked until provided.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var toolbar: some View {
        let vm = app.testCases
        return HStack {
            Button("Select All") { vm.selectAll(true) }
            Button("None") { vm.selectAll(false) }
            Button { vm.approveAllSelected() } label: { Label("Approve All (\(vm.pendingReviewCount))", systemImage: "checkmark.seal") }
                .disabled(vm.pendingReviewCount == 0)
                .help("Cho phép chạy mọi case đang chọn có trạng thái Needs Review. Case không có bước kiểm tra vẫn sẽ kết thúc là Needs Review.")
            Button { vm.addCase(); editing = true } label: { Label("Thêm test case", systemImage: "plus") }
                .disabled(vm.plan == nil)
            Text("\(vm.selectedIDs.count) of \(vm.cases.count) selected").foregroundStyle(.secondary)
            if !vm.casesWithMissingData.isEmpty {
                Text("⚠︎ \(vm.casesWithMissingData.count) case(s) need test data").foregroundStyle(.orange)
            }
            Spacer()
            Button { Task { await app.translatePlan() } } label: { Label("Dịch sang tiếng Việt", systemImage: "character.bubble") }
                .disabled(vm.isGenerating || !vm.cases.contains { LocalAIService.needsTranslation($0.draft) })
            Button { Task { await app.analyze() } } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                .disabled(vm.isGenerating || app.github.snapshot == nil)
            Button { Task { await app.generateAndRun() } } label: { Label("Generate & Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating || app.runner.isRunning || app.github.snapshot == nil || vm.selectedIDs.isEmpty && !vm.cases.isEmpty)
        }
        .padding(12)
    }
}
