import SwiftUI
import SwiftData

/// Every issue imported so far (cached locally), with its generated plan versions and test runs.
struct HistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \GitHubIssueRecord.fetchedAt, order: .reverse) private var issues: [GitHubIssueRecord]
    @Query(sort: \TestPlanRecord.createdAt, order: .reverse) private var plans: [TestPlanRecord]
    @Query(sort: \TestRunRecord.startedAt, order: .reverse) private var runs: [TestRunRecord]
    @State private var selectedURL: String?
    @State private var search = ""
    @State private var pendingDelete: GitHubIssueRecord?

    private var filtered: [GitHubIssueRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return issues }
        return issues.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
    }

    private var selected: GitHubIssueRecord? { issues.first { $0.url == selectedURL } ?? filtered.first }

    var body: some View {
        Group {
            if issues.isEmpty {
                ContentUnavailableView("No imported issues yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Issues you fetch from GitHub are cached here."))
            } else {
                HSplitView {
                    List(filtered, selection: $selectedURL) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title).lineLimit(2)
                            Text("\(record.owner)/\(record.repo)#\(record.number)").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(record.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("rev \(record.revision)")
                                Text("\(plans.filter { $0.issueURL == record.url }.count) plan(s)")
                                Text("\(runs.filter { $0.issueURL == record.url }.count) run(s)")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(record.url)
                    }
                    .searchable(text: $search, placement: .sidebar, prompt: "Search issues")
                    .frame(minWidth: 300, idealWidth: 340)

                    if let record = selected { detail(record).frame(minWidth: 460) }
                }
            }
        }
        .navigationTitle("Issue History")
        .toolbar {
            ToolbarItem {
                Button { app.newIssue() } label: { Label("New Issue", systemImage: "plus") }
            }
        }
        .confirmationDialog("Remove this issue from local history?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { record in
            Button("Remove issue, plans and runs", role: .destructive) { remove(record) }
        } message: { _ in
            Text("Only local data is deleted. Nothing on GitHub is touched.")
        }
    }

    private func detail(_ record: GitHubIssueRecord) -> some View {
        let issuePlans = plans.filter { $0.issueURL == record.url }
        let issueRuns = runs.filter { $0.issueURL == record.url }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(record.title).font(.title2.bold()).textSelection(.enabled)
                Link(record.url, destination: URL(string: record.url) ?? URL(string: "https://github.com")!).font(.caption)
                Text("Imported \(record.fetchedAt.formatted()) · GitHub updated \(record.issueUpdatedAt.formatted()) · revision \(record.revision)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { app.openFromHistory(record, plan: issuePlans.first) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { pendingDelete = record } label: { Label("Remove", systemImage: "trash") }
                }

                Card(title: "Generated plans (\(issuePlans.count))") {
                    if issuePlans.isEmpty { Text("No test cases generated yet.").foregroundStyle(.secondary) }
                    ForEach(issuePlans) { plan in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Plan v\(plan.version) · \(plan.model)").font(.body.weight(.medium))
                                Text(plan.createdAt.formatted() + (plan.issueHash != record.contentHash ? " · issue changed since" : ""))
                                    .font(.caption).foregroundStyle(plan.issueHash != record.contentHash ? .orange : .secondary)
                            }
                            Spacer()
                            Button("Load") { app.openFromHistory(record, plan: plan) }
                        }
                    }
                }

                Card(title: "Test runs (\(issueRuns.count))") {
                    if issueRuns.isEmpty { Text("Not executed yet.").foregroundStyle(.secondary) }
                    ForEach(issueRuns) { run in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(run.startedAt.formatted()).font(.body.weight(.medium))
                                Text("\(run.deviceName) · iOS \(run.osVersion) · plan v\(run.planVersion)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(run.count(.passed))✓ \(run.count(.failed))✗ \(run.count(.blocked))⚠ \(run.count(.needsReview))?")
                                .font(.caption.monospacedDigit())
                            Button("Report") { ReportActions.export(run) }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func remove(_ record: GitHubIssueRecord) {
        let url = record.url
        for plan in plans where plan.issueURL == url { context.delete(plan) }
        for run in runs where run.issueURL == url { context.delete(run) }
        let cases = (try? context.fetch(FetchDescriptor<GeneratedTestCase>(predicate: #Predicate { $0.issueURL == url }))) ?? []
        for item in cases { context.delete(item) }
        context.delete(record)
        try? context.save()
        if app.github.snapshot?.htmlURL == url { app.github.snapshot = nil; app.testCases.clear() }
        selectedURL = nil
    }
}
