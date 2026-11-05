import SwiftUI

struct GitHubImportView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var github = app.github
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "GitHub connection (read-only)") {
                    HStack {
                        Image(systemName: github.isConnected ? "checkmark.seal.fill" : "key")
                            .foregroundStyle(github.isConnected ? .green : .secondary)
                        Text(github.tokenStatus).textSelection(.enabled)
                    }
                    if github.isConnected {
                        Button("Disconnect (remove token from Keychain)") { github.disconnect() }
                    } else {
                        HStack {
                            SecureField("Fine-grained token with read-only Issues permission", text: $github.tokenInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") { Task { await github.connect() } }
                                .disabled(github.tokenInput.isEmpty || github.isCheckingToken)
                        }
                    }
                    Text("The token is stored in the macOS Keychain. The app only issues GET requests; issues, checkboxes and comments are never modified.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Issue") {
                    HStack {
                        TextField("https://github.com/OWNER/REPOSITORY/issues/123", text: $github.urlInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await github.fetch() } }
                        Button { Task { await github.fetch() } } label: {
                            if github.isFetching { ProgressView().controlSize(.small) } else { Text("Fetch Issue") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(github.urlInput.isEmpty || github.isFetching)
                    }
                    TextField("Application context (optional): what the app does, login state, test accounts…", text: $github.appContext, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                }

                if let error = github.error { ErrorBanner(text: error) }
                if let notice = github.changeNotice { InfoBanner(text: notice) }

                if let issue = github.snapshot { issueView(issue) }
            }
            .padding(24)
        }
        .navigationTitle("GitHub Issue Import")
        .task(id: app.github.snapshot?.contentHash) { if let issue = app.github.snapshot { TranslationStore.shared.request(issue: issue) } }
        .toolbar {
            ToolbarItem {
                Button { app.newIssue() } label: { Label("New Issue", systemImage: "plus") }
                    .help("Clear the current issue and import a new one (history is kept)")
            }
        }
    }

    @ViewBuilder
    private func issueView(_ issue: IssueSnapshot) -> some View {
        Card(title: "\(issue.reference) · \(issue.state) · revision \(app.github.revision)") {
            Text(vi(issue.title)).font(.title2.bold()).textSelection(.enabled).help(issue.title)
            if !issue.labels.isEmpty { Text(issue.labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            Link(issue.htmlURL, destination: URL(string: issue.htmlURL) ?? URL(string: "https://github.com")!).font(.caption)
            Divider()
            Text(issue.body.isEmpty ? "(no description)" : String(issue.body.prefix(4000)).split(separator: "\n", omittingEmptySubsequences: false).map { vi(String($0)) }.joined(separator: "\n"))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(issue.comments.count) comment(s) loaded").font(.caption).foregroundStyle(.secondary)
        }

        Card(title: "Checklist (\(issue.checklist.count)) · Requirements (\(issue.requirements.count))") {
            if issue.checklist.isEmpty {
                InfoBanner(text: "No Markdown checklist found. Test cases can only be derived from acceptance criteria / requirements, if present.")
            }
            ForEach(groups(of: issue.checklist), id: \.title) { group in
                Toggle(isOn: Binding(
                    get: { group.items.allSatisfy { !app.github.excluded.contains($0.id) } },
                    set: { on in group.items.forEach { if on { app.github.excluded.remove($0.id) } else { app.github.excluded.insert($0.id) } } })) {
                    Text(vi(group.title)).font(.subheadline.bold())
                }
                ForEach(group.items) { item in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { !app.github.excluded.contains(item.id) },
                                                 set: { on in if on { app.github.excluded.remove(item.id) } else { app.github.excluded.insert(item.id) } }))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.id)  \(vi(item.text))").textSelection(.enabled).help(item.text)
                            if let steps = item.providedSteps { Text("Các bước: \(vi(steps))").font(.caption).foregroundStyle(.secondary) }
                            if let expected = item.providedExpected { Text("Kết quả mong đợi: \(vi(expected))").font(.caption).foregroundStyle(.secondary) }
                            Text("\(item.source) · line \(item.line)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Text("Sẽ phân tích \(issue.checklist.count - app.github.excluded.count)/\(issue.checklist.count) mục — bỏ tick mục/nhóm không cần để sinh nhanh hơn.")
                .font(.caption).foregroundStyle(.secondary)
            if !issue.requirements.isEmpty { Divider() }
            ForEach(issue.requirements) { requirement in
                Text("\(requirement.id) [\(requirement.kind)] \(vi(requirement.text))").font(.callout).textSelection(.enabled)
            }
        }

        HStack {
            Button { app.analyzeAndShow() } label: { Label("Analyze with Local AI", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { app.quickGenerate() } label: { Label("Tạo nhanh (không AI)", systemImage: "bolt") }
                .controlSize(.large)
                .help("Dùng nguyên văn bước / kết quả mong đợi của issue, tạo ngay lập tức không gọi model")
            Button("Check for changes") { Task { await app.github.checkForChanges() } }
            Text("Model: \(Prefs.ollamaModel.isEmpty ? "none selected (Settings)" : Prefs.ollamaModel)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groups(of items: [ChecklistItem]) -> [(title: String, items: [ChecklistItem])] {
        var order: [String] = []
        var buckets: [String: [ChecklistItem]] = [:]
        for item in items {
            let key = item.section ?? "(không có nhóm)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { (title: $0, items: buckets[$0] ?? []) }
    }
}
