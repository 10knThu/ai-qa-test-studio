import SwiftUI
import SwiftData
import AppKit

enum ReportActions {
    /// Lets the user pick a folder, then writes report.html + report.json + evidence there.
    @MainActor
    static func export(_ run: TestRunRecord) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the HTML and JSON report."
        panel.directoryURL = AppPaths.exports
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try ReportExporter.export(run: run, to: parent)
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("report.html")])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

struct ReportsView: View {
    @Query(sort: \TestRunRecord.startedAt, order: .reverse) private var runs: [TestRunRecord]
    @State private var selectedRunID: UUID?

    private var selectedRun: TestRunRecord? { runs.first { $0.id == selectedRunID } ?? runs.first }

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView("No reports yet", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Run test cases to create a report."))
                .navigationTitle("Reports")
        } else {
            HSplitView {
                List(runs, selection: $selectedRunID) { run in
                    VStack(alignment: .leading) {
                        Text(run.issueTitle).lineLimit(1)
                        Text(run.startedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text("\(run.count(.passed)) passed · \(run.count(.failed)) failed · \(run.count(.blocked)) blocked")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(run.id)
                }
                .frame(minWidth: 240, idealWidth: 280)
                if let run = selectedRun { RunDetailView(run: run).frame(minWidth: 520) }
            }
            .navigationTitle("Reports")
        }
    }
}

struct RunDetailView: View {
    let run: TestRunRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(run.issueTitle).font(.title2.bold())
                    Spacer()
                    Button { ReportActions.export(run) } label: { Label("Export HTML + JSON", systemImage: "square.and.arrow.up") }
                }
                if let problem = run.infrastructureProblem { ErrorBanner(text: problem) }

                HStack(spacing: 10) {
                    ForEach([ExecutionStatus.passed, .failed, .blocked, .needsReview, .cancelled], id: \.self) { status in
                        Card(title: status.title) {
                            Text("\(run.count(status))").font(.title.bold()).foregroundStyle(status.color)
                        }
                    }
                }

                Card(title: "Build & device") {
                    LabeledContent("Device", value: "\(run.deviceName) · iOS \(run.osVersion)")
                    LabeledContent("Bundle ID", value: run.appBundleID)
                    LabeledContent("App", value: run.appPath).lineLimit(1)
                    LabeledContent("Local AI model", value: "\(run.model) · plan v\(run.planVersion) · issue rev \(run.issueRevision)")
                    LabeledContent("Started", value: run.startedAt.formatted())
                    LabeledContent("Finished", value: run.finishedAt?.formatted() ?? "—")
                    HStack {
                        if let path = run.buildLogPath { Button("Build log") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
                        if let path = run.runLogPath { Button("Run log") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
                    }
                }

                Card(title: "Timeline & results") {
                    ForEach(run.caseRuns.sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }) { record in
                        DisclosureGroup {
                            ForEach(record.steps.sorted { $0.index < $1.index }) { step in
                                HStack(alignment: .top) {
                                    Image(systemName: step.status.symbol).foregroundStyle(step.status.color)
                                    VStack(alignment: .leading) {
                                        Text(step.actionSummary).font(.caption.monospaced())
                                        Text(step.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Text(formatDuration(step.duration)).font(.caption.monospacedDigit())
                                }
                            }
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(record.evidence.filter { $0.path.hasSuffix(".png") }) { evidence in
                                        if let image = NSImage(contentsOfFile: evidence.path) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(height: 220)
                                                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: evidence.path)) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                StatusBadge(status: record.status)
                                Text("\(record.caseID) \(record.title)").lineLimit(1)
                                Spacer()
                                Text(formatDuration(record.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if !record.message.isEmpty {
                            Text(record.message).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
