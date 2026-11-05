import SwiftUI

struct TestRunnerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let runner = app.runner
        VStack(spacing: 0) {
            if let problem = runner.infrastructureProblem {
                ErrorBanner(text: "Infrastructure problem (not a test failure): \(problem)").padding(12)
            }
            HSplitView {
                caseList.frame(minWidth: 260, idealWidth: 300)
                center.frame(minWidth: 380)
                rightPane.frame(minWidth: 340, idealWidth: 400)
            }
            Divider()
            bottomBar
        }
        .navigationTitle("Test Runner")
        .task(id: app.testCases.cases.map(\.id)) { TranslationStore.shared.request(cases: app.testCases.cases) }
    }

    // MARK: Left — test case list

    private var caseList: some View {
        let runner = app.runner
        let cases = runner.runCases.isEmpty ? app.testCases.selectedCases : runner.runCases
        return List(selection: Binding(get: { runner.focusedID }, set: { runner.focusedID = $0 })) {
            ForEach(cases) { planned in
                let status = runner.statuses[planned.id] ?? .notRun
                HStack {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    VStack(alignment: .leading) {
                        Text("\(planned.id)  \(vi(planned.draft.title))").lineLimit(2).help(planned.draft.title)
                        HStack {
                            Text(status.title).font(.caption).foregroundStyle(status.color)
                            if let duration = runner.durations[planned.id] {
                                Text(formatDuration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .tag(planned.id)
                .contextMenu {
                    Button("Bỏ qua test case này", systemImage: "forward.end.fill") { runner.skip(planned.id) }
                        .disabled(!runner.isRunning || status == .passed || status == .failed || status == .skipped)
                }
            }
        }
        .overlay { if cases.isEmpty { Text("No test cases selected.").foregroundStyle(.secondary) } }
    }

    // MARK: Center — current testcase

    private var center: some View {
        let runner = app.runner
        let focusID = runner.currentCaseID ?? runner.focusedID
        let planned = (runner.runCases + app.testCases.cases).first { $0.id == focusID }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: runner.progress) {
                    Text("\(runner.completed) of \(runner.total) test cases finished")
                }
                if let planned {
                    Text("\(planned.id) — \(vi(planned.draft.title))").font(.title3.bold()).help(planned.draft.title)
                    if let status = runner.statuses[planned.id] { StatusBadge(status: status) }
                    if let message = runner.messages[planned.id] { Text(message).textSelection(.enabled) }
                }
                if let action = runner.currentAction, runner.isRunning {
                    Card(title: "Current action  \(runner.currentActionIndex + 1)/\(runner.currentActionCount)") {
                        HStack { ProgressView().controlSize(.small); Text(action.summary).font(.body.monospaced()) }
                        if !action.expectedOutcome.isEmpty { Text("Expected: \(action.expectedOutcome)").foregroundStyle(.secondary) }
                    }
                }
                if let planned { flowCard(planned, runner: runner) }
                if let planned, let note = runner.flowNotes[planned.id] {
                    Card(title: "Ghi chú luồng đã chạy") { Text(note).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if let planned {
                    Card(title: "Expected result") {
                        ForEach(planned.draft.expectedResults, id: \.self) { Text("• \(vi($0))").textSelection(.enabled).help($0) }
                    }
                    if let steps = runner.stepResults[planned.id], let last = steps.last {
                        Card(title: "Actual result") {
                            Text(last.actual).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// The route this case follows: how the screen is reached, then each action with its live status.
    private func flowCard(_ planned: PlannedCase, runner: RunnerViewModel) -> some View {
        let results = runner.stepResults[planned.id] ?? []
        let running = runner.currentCaseID == planned.id
        return Card(title: "Luồng chạy của test case") {
            if let nav = runner.navigationInfo {
                Label("Màn hình đích “\(nav.goal)” — \(nav.origin.title)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.callout)
                if !nav.path.isEmpty {
                    Text(nav.path.enumerated().map { "\($0.offset + 1). Bấm “\($0.element)”" }.joined(separator: "   "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else if !runner.navigationGoal.isEmpty, runner.autoNavigate {
                Text("Chưa điều hướng tới “\(runner.navigationGoal)”").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(planned.actions.enumerated()), id: \.offset) { index, action in
                let done = results.first { $0.action.id == action.id }
                HStack(alignment: .top, spacing: 6) {
                    if let done {
                        Image(systemName: done.status.symbol).foregroundStyle(done.status.color)
                    } else if running && runner.currentActionIndex == index {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text("\(index + 1). \(action.summary)").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if planned.actions.isEmpty { Text("Test case chưa có action nào.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Right — logs & assertion details

    private var rightPane: some View {
        let runner = app.runner
        let steps = runner.stepResults[runner.focusedID ?? ""] ?? []
        return VSplitView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Execution log").font(.headline)
                LogView(log: runner.log, minHeight: 160)
            }
            .padding(10).frame(minHeight: 200)
            VStack(alignment: .leading, spacing: 4) {
                Text("Assertions & errors").font(.headline)
                List(steps, id: \.action.id) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: step.status.symbol).foregroundStyle(step.status.color)
                            Text(step.action.summary).font(.caption.monospaced()).lineLimit(2)
                        }
                        if step.status != .passed || step.action.type.isAssertion {
                            Text(step.message).font(.caption).foregroundStyle(step.status == .passed ? Color.secondary : step.status.color)
                                .textSelection(.enabled)
                        }
                        if let locator = step.locatorUsed {
                            Text("locator: \(locator)\(step.aiSuggestedLocator ? " (AI-suggested, validated live)" : "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10).frame(minHeight: 140)
        }
    }

    // MARK: Bottom toolbar

    private var bottomBar: some View {
        let runner = app.runner
        return HStack {
            if runner.isRunning {
                Button(role: .destructive) { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                Button { runner.skipCurrent() } label: { Label("Bỏ qua test case", systemImage: "forward.end.fill") }
                    .disabled(runner.currentCaseID == nil)
                    .help("Dừng test case đang chạy ngay sau bước hiện tại và chạy tiếp case kế. Chuột phải vào một case trong danh sách để bỏ qua case chưa chạy.")
            } else {
                Menu {
                    Button("Run All") { Task { await app.run(cases: app.testCases.cases) } }
                    Button("Run Selected") { Task { await app.run(cases: app.testCases.selectedCases) } }
                } label: { Label("Run", systemImage: "play.fill") }
                .menuStyle(.borderedButton).fixedSize()
                .disabled(app.testCases.cases.isEmpty || app.source.isBusy)
            }
            Button { runner.retryFailed() } label: { Label("Retry Failed", systemImage: "arrow.counterclockwise") }
                .disabled(runner.isRunning || runner.retryableCases.isEmpty)
            if !runner.isRunning {
                @Bindable var bindable = runner
                Toggle("Tự điều hướng tới màn hình", isOn: $bindable.autoNavigate).toggleStyle(.checkbox)
                TextField("Nhãn màn hình đích, vd: Shop注文履歴", text: $bindable.navigationGoal)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .disabled(!runner.autoNavigate)
                    .help("Chữ hiển thị của màn hình cần test (tiêu đề). App đọc source để tìm luồng, rồi tự bấm tới đó trước mỗi test case.")
            }
            if app.source.isBusy {
                Button("Cancel build") { app.source.cancel() }
                ProgressView().controlSize(.small)
                Text(app.source.currentOperation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { if let run = runner.currentRun { ReportActions.export(run) } } label: { Label("Export Report", systemImage: "square.and.arrow.up") }
                .disabled(runner.currentRun == nil || runner.isRunning)
        }
        .padding(12)
    }
}
