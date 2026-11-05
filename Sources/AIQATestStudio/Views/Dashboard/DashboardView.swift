import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \QAProject.updatedAt, order: .reverse) private var projects: [QAProject]
    @Query(sort: \TestRunRecord.startedAt, order: .reverse) private var runs: [TestRunRecord]

    private var totals: [(ExecutionStatus, Int)] {
        [ExecutionStatus.passed, .failed, .blocked, .needsReview, .cancelled].map { status in
            (status, runs.reduce(0) { $0 + $1.count(status) })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("AI QA Test Studio").font(.largeTitle.bold())
                Text("Generate and run iOS test cases from GitHub Issues — entirely on this Mac.").foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button { app.selection = .github } label: { Label("Import GitHub Issue", systemImage: "arrow.down.doc") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { app.selection = .source } label: { Label("Select Source Project", systemImage: "folder") }
                        .controlSize(.large)
                }

                HStack(spacing: 12) {
                    ForEach(totals, id: \.0) { status, count in
                        Card(title: status.title) {
                            Text("\(count)").font(.system(size: 34, weight: .bold)).foregroundStyle(status.color)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: "Recent projects") {
                        if projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                        ForEach(projects.prefix(6)) { project in
                            VStack(alignment: .leading) {
                                Text(project.name).font(.body.weight(.medium))
                                Text(project.sourcePath ?? project.issueURL ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Card(title: "Recent test runs") {
                        if runs.isEmpty { Text("No runs yet.").foregroundStyle(.secondary) }
                        ForEach(runs.prefix(6)) { run in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(run.issueTitle).lineLimit(1)
                                    Text(run.startedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(run.count(.passed))✓ \(run.count(.failed))✗ \(run.count(.blocked))⚠")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }
}
