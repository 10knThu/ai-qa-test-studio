import Foundation

struct ReportDocument: Codable {
    struct Step: Codable {
        var index: Int; var action: String; var status: String; var expected: String; var actual: String
        var message: String; var durationSeconds: Double; var locator: String?; var aiSuggestedLocator: Bool; var screenshot: String?
    }
    struct CaseResult: Codable {
        var id: String; var title: String; var category: String; var status: String; var message: String
        var durationSeconds: Double; var steps: [Step]; var evidence: [String]
        var flowNote: String = ""
    }
    var generatedAt: Date
    var issueURL: String
    var issueTitle: String
    var issueRevision: Int
    var planVersion: Int
    var model: String
    var device: String
    var osVersion: String
    var appBundleID: String
    var startedAt: Date
    var finishedAt: Date?
    var infrastructureProblem: String?
    var summary: [String: Int]
    var cases: [CaseResult]
}

enum ReportExporter {
    static func document(for run: TestRunRecord, evidenceFolder: String = "evidence") -> ReportDocument {
        func shortName(_ path: String?) -> String? {
            path.map { "\(evidenceFolder)/\(URL(fileURLWithPath: $0).lastPathComponent)" }
        }
        let cases = run.caseRuns.sorted { $0.caseID < $1.caseID }.map { record in
            ReportDocument.CaseResult(
                id: record.caseID, title: record.title, category: record.category, status: record.status.title,
                message: record.message, durationSeconds: record.duration,
                steps: record.steps.sorted { $0.index < $1.index }.map { step in
                    .init(index: step.index + 1, action: step.actionSummary, status: step.status.title, expected: step.expected,
                          actual: step.actual, message: step.message, durationSeconds: step.duration,
                          locator: step.locatorUsed, aiSuggestedLocator: step.aiSuggestedLocator, screenshot: shortName(step.screenshotPath))
                },
                evidence: record.evidence.compactMap { shortName($0.path) }, flowNote: record.flowNote)
        }
        var summary: [String: Int] = [:]
        for status in ExecutionStatus.allCases { summary[status.title] = run.count(status) }
        return ReportDocument(generatedAt: Date(), issueURL: run.issueURL, issueTitle: run.issueTitle, issueRevision: run.issueRevision,
                              planVersion: run.planVersion, model: run.model, device: run.deviceName, osVersion: run.osVersion,
                              appBundleID: run.appBundleID, startedAt: run.startedAt, finishedAt: run.finishedAt,
                              infrastructureProblem: run.infrastructureProblem, summary: summary, cases: cases)
    }

    /// Writes report.json, report.html and copies evidence next to them. Returns the folder.
    @discardableResult
    static func export(run: TestRunRecord, to parent: URL) throws -> URL {
        let stamp = run.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let folder = parent.appendingPathComponent("AIQA-Report-\(stamp)", isDirectory: true)
        let evidenceFolder = folder.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceFolder, withIntermediateDirectories: true)

        let paths = run.caseRuns.flatMap { record in record.evidence.map(\.path) + record.steps.compactMap(\.screenshotPath) }
        for path in Set(paths) where FileManager.default.fileExists(atPath: path) {
            let destination = evidenceFolder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(atPath: path, toPath: destination.path)
        }

        let doc = document(for: run)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: folder.appendingPathComponent("report.json"))
        try html(for: doc).write(to: folder.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        return folder
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(for doc: ReportDocument) -> String {
        let colors = ["Passed": "#1a7f37", "Failed": "#cf222e", "Blocked": "#bc4c00", "Needs Review": "#9a6700",
                      "Cancelled": "#8250df", "Not Run": "#6e7781", "Skipped": "#6e7781", "Running": "#0969da"]
        func badge(_ status: String) -> String {
            "<span class=\"badge\" style=\"background:\(colors[status] ?? "#6e7781")\">\(escape(status))</span>"
        }
        var out = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>AI QA Test Report</title>
        <style>pre.flow{background:#f6f8fa;padding:8px;white-space:pre-wrap;font:12px ui-monospace,Menlo,monospace}body{font:14px -apple-system,Helvetica,sans-serif;margin:32px;color:#1f2328}h1{margin-bottom:4px}
        .badge{color:#fff;border-radius:10px;padding:2px 9px;font-size:12px}table{border-collapse:collapse;width:100%;margin:8px 0}
        td,th{border:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top}th{background:#f6f8fa}
        .meta td:first-child{width:160px;font-weight:600}img{max-width:220px;border:1px solid #d0d7de;margin:4px}
        .case{margin-top:24px}.sum span{margin-right:14px}</style></head><body>
        <h1>AI QA Test Report</h1><p>\(escape(doc.issueTitle)) — <a href="\(escape(doc.issueURL))">\(escape(doc.issueURL))</a></p>
        <table class="meta">
        <tr><td>Device</td><td>\(escape(doc.device)) · iOS \(escape(doc.osVersion))</td></tr>
        <tr><td>App bundle id</td><td>\(escape(doc.appBundleID))</td></tr>
        <tr><td>Local AI model</td><td>\(escape(doc.model)) · plan v\(doc.planVersion) · issue revision \(doc.issueRevision)</td></tr>
        <tr><td>Started</td><td>\(doc.startedAt.formatted())</td></tr>
        <tr><td>Finished</td><td>\(doc.finishedAt?.formatted() ?? "—")</td></tr>
        """
        if let problem = doc.infrastructureProblem {
            out += "<tr><td>Infrastructure problem</td><td style=\"color:#cf222e\">\(escape(problem))</td></tr>"
        }
        out += "</table><p class=\"sum\">"
        for status in ["Passed", "Failed", "Blocked", "Needs Review", "Cancelled", "Not Run"] {
            out += "<span>\(badge(status)) \(doc.summary[status] ?? 0)</span>"
        }
        out += "</p>"
        for item in doc.cases {
            out += "<div class=\"case\"><h3>\(escape(item.id)) — \(escape(item.title)) \(badge(item.status))</h3>"
            out += "<p>\(escape(item.category)) · \(String(format: "%.1f", item.durationSeconds))s — \(escape(item.message))</p>"
            if !item.flowNote.isEmpty { out += "<pre class=\"flow\">\(escape(item.flowNote))</pre>" }
            if !item.steps.isEmpty {
                out += "<table><tr><th>#</th><th>Action</th><th>Status</th><th>Expected</th><th>Actual</th><th>Time</th></tr>"
                for step in item.steps {
                    let locator = step.locator.map { "<br><small>locator: \(escape($0))\(step.aiSuggestedLocator ? " (AI-suggested, validated)" : "")</small>" } ?? ""
                    out += "<tr><td>\(step.index)</td><td>\(escape(step.action))\(locator)</td><td>\(badge(step.status))</td><td>\(escape(step.expected))</td><td>\(escape(step.actual))</td><td>\(String(format: "%.1f", step.durationSeconds))s</td></tr>"
                }
                out += "</table>"
            }
            for image in item.evidence where image.hasSuffix(".png") { out += "<a href=\"\(escape(image))\"><img src=\"\(escape(image))\"></a>" }
            out += "</div>"
        }
        return out + "</body></html>"
    }
}
