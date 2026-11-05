import SwiftUI

/// Manual editing of one test case: text fields plus the executable actions the runner will perform.
struct CaseEditorView: View {
    @Environment(AppState.self) private var app
    let planned: PlannedCase

    private var vm: TestCasesViewModel { app.testCases }
    private let argumentKey: [ActionType: String] = [.typeText: "text", .assertText: "expectedText", .swipe: "direction", .scroll: "direction"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Tiêu đề", text: bind(\.draft.title)).textFieldStyle(.roundedBorder).font(.title3.bold())
            Picker("Độ ưu tiên", selection: bind(\.draft.priority)) {
                ForEach(CasePriority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            LinesEditor(title: "Điều kiện tiên quyết (mỗi dòng một ý)", lines: bind(\.draft.preconditions)).id(planned.id + "pre")
            LinesEditor(title: "Các bước (mỗi dòng một bước)", lines: bind(\.draft.steps)).id(planned.id + "steps")
            LinesEditor(title: "Kết quả mong đợi (mỗi dòng một ý)", lines: bind(\.draft.expectedResults)).id(planned.id + "exp")

            Text("Action sẽ chạy").font(.headline)
            if !planned.notes.isEmpty { InfoBanner(text: planned.notes.joined(separator: "\n")) }
            ForEach(Array(planned.actions.enumerated()), id: \.offset) { index, action in actionRow(index, action) }
            Menu {
                ForEach(ActionType.allCases, id: \.self) { type in
                    Button(type.rawValue) { vm.edit(planned.id) { $0.actions.append(CaseEditing.blankAction(type, caseID: planned.id)) } }
                }
            } label: { Label("Thêm action", systemImage: "plus") }
                .menuStyle(.borderedButton).fixedSize()
        }
    }

    private func actionRow(_ index: Int, _ action: TestAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(index + 1).").font(.caption.monospaced())
                Picker("", selection: actionBinding(index, \.type)) {
                    ForEach(ActionType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 150)
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == planned.actions.count - 1)
                Button(role: .destructive) { vm.edit(planned.id) { $0.actions.remove(at: index) } } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)

            if action.type.needsTarget {
                HStack {
                    Picker("", selection: locatorStrategy(index)) {
                        ForEach(LocatorStrategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    TextField("Giá trị (id / chữ hiển thị)", text: locatorValue(index)).textFieldStyle(.roundedBorder)
                }
            }
            if let key = argumentKey[action.type] {
                TextField(key == "direction" ? "Hướng: up / down / left / right" : key == "text" ? "Text cần nhập" : "Text mong đợi",
                          text: Binding(get: { action.arguments[key] ?? "" },
                                        set: { value in vm.edit(planned.id) { $0.actions[index].arguments[key] = value } }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Kết quả mong đợi của bước này", text: actionBinding(index, \.expectedOutcome)).textFieldStyle(.roundedBorder)
                Stepper("\(Int(action.timeoutSeconds))s", value: actionBinding(index, \.timeoutSeconds), in: 1...60, step: 1)
                    .fixedSize().font(.caption)
            }
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Bindings

    private func bind<V>(_ keyPath: WritableKeyPath<PlannedCase, V>) -> Binding<V> {
        Binding(get: { planned[keyPath: keyPath] }, set: { value in vm.edit(planned.id) { $0[keyPath: keyPath] = value } })
    }

    private func actionBinding<V>(_ index: Int, _ keyPath: WritableKeyPath<TestAction, V>) -> Binding<V> {
        Binding(get: { planned.actions[index][keyPath: keyPath] },
                set: { value in vm.edit(planned.id) { if $0.actions.indices.contains(index) { $0.actions[index][keyPath: keyPath] = value } } })
    }

    private func locatorStrategy(_ index: Int) -> Binding<LocatorStrategy> {
        Binding(get: { planned.actions[index].target?.strategy ?? .label },
                set: { value in vm.edit(planned.id) { $0.actions[index].target = Locator(strategy: value, value: $0.actions[index].target?.value ?? "",
                                                                                          elementType: $0.actions[index].target?.elementType) } })
    }

    private func locatorValue(_ index: Int) -> Binding<String> {
        Binding(get: { planned.actions[index].target?.value ?? "" },
                set: { value in vm.edit(planned.id) {
                    var target = $0.actions[index].target ?? Locator(strategy: .label, value: "")
                    target.value = value
                    $0.actions[index].target = target
                } })
    }

    private func move(_ index: Int, by offset: Int) {
        vm.edit(planned.id) { $0.actions.swapAt(index, index + offset) }
    }
}

/// Multi-line editor for a `[String]`: one entry per line. Keeps its own text so blank lines survive while typing.
struct LinesEditor: View {
    let title: String
    @Binding var lines: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body).frame(minHeight: 54, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: text) {
                    lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
                }
        }
        .onAppear { text = lines.joined(separator: "\n") }
    }
}
