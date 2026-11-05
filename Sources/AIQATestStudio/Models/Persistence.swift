import Foundation
import SwiftData

// Structured records live in SwiftData. Screenshots and large logs live on disk (paths stored here).
// The GitHub token is NEVER stored here (Keychain only).

@Model final class QAProject {
    var id: UUID = UUID()
    var name: String = ""
    var issueURL: String?
    var sourcePath: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(name: String, issueURL: String? = nil, sourcePath: String? = nil) {
        self.name = name
        self.issueURL = issueURL
        self.sourcePath = sourcePath
    }
}

@Model final class GitHubIssueRecord {
    var url: String = ""
    var owner: String = ""
    var repo: String = ""
    var number: Int = 0
    var title: String = ""
    var snapshotJSON: Data = Data()
    var contentHash: String = ""
    /// Incremented every time a re-import detects changed content.
    var revision: Int = 1
    var issueUpdatedAt: Date = Date()
    var fetchedAt: Date = Date()

    init(url: String, owner: String, repo: String, number: Int, title: String, snapshotJSON: Data,
         contentHash: String, issueUpdatedAt: Date) {
        self.url = url; self.owner = owner; self.repo = repo; self.number = number; self.title = title
        self.snapshotJSON = snapshotJSON; self.contentHash = contentHash; self.issueUpdatedAt = issueUpdatedAt
    }
}

@Model final class GeneratedTestCase {
    var issueURL: String = ""
    var caseID: String = ""
    var title: String = ""
    var category: String = ""
    var planVersion: Int = 1
    var plannedCaseJSON: Data = Data()
    var createdAt: Date = Date()

    init(issueURL: String, caseID: String, title: String, category: String, planVersion: Int, plannedCaseJSON: Data) {
        self.issueURL = issueURL; self.caseID = caseID; self.title = title
        self.category = category; self.planVersion = planVersion; self.plannedCaseJSON = plannedCaseJSON
    }
}

@Model final class TestPlanRecord {
    var issueURL: String = ""
    var version: Int = 1
    var issueHash: String = ""
    var model: String = ""
    var planJSON: Data = Data()
    var createdAt: Date = Date()

    init(issueURL: String, version: Int, issueHash: String, model: String, planJSON: Data) {
        self.issueURL = issueURL; self.version = version; self.issueHash = issueHash
        self.model = model; self.planJSON = planJSON
    }
}

@Model final class SourceProjectRecord {
    var path: String = ""
    var bookmark: Data?
    var containerPath: String = ""
    var containerKind: String = ""
    var scheme: String = ""
    var configuration: String = "Debug"
    var bundleIdentifier: String = ""
    var lastUsed: Date = Date()

    init(path: String) { self.path = path }
}

@Model final class BuildRecord {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var finishedAt: Date?
    var success: Bool = false
    var scheme: String = ""
    var configuration: String = ""
    var projectPath: String = ""
    var simulatorUDID: String = ""
    var simulatorName: String = ""
    var osVersion: String = ""
    var appPath: String?
    var bundleIdentifier: String?
    var logPath: String?
    var errorSummary: String?
    /// Issue this build was made for — one build per issue, reused for every test run of that issue.
    var issueURL: String?

    init(scheme: String, configuration: String, projectPath: String, simulatorUDID: String,
         simulatorName: String, osVersion: String) {
        self.scheme = scheme; self.configuration = configuration; self.projectPath = projectPath
        self.simulatorUDID = simulatorUDID; self.simulatorName = simulatorName; self.osVersion = osVersion
    }
}

@Model final class TestRunRecord {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var finishedAt: Date?
    var issueURL: String = ""
    var issueTitle: String = ""
    var issueRevision: Int = 1
    var planVersion: Int = 1
    var model: String = ""
    var deviceName: String = ""
    var osVersion: String = ""
    var appBundleID: String = ""
    var appPath: String = ""
    var buildLogPath: String?
    var runLogPath: String?
    var infrastructureProblem: String?
    @Relationship(deleteRule: .cascade, inverse: \TestCaseRunRecord.run)
    var caseRuns: [TestCaseRunRecord] = []

    init(issueURL: String, issueTitle: String) {
        self.issueURL = issueURL; self.issueTitle = issueTitle
    }

    func count(_ status: ExecutionStatus) -> Int { caseRuns.filter { $0.status == status }.count }
}

@Model final class TestCaseRunRecord {
    var caseID: String = ""
    var title: String = ""
    var category: String = ""
    var statusRaw: String = ExecutionStatus.notRun.rawValue
    var message: String = ""
    /// Plain-text note of how this case was run: route to the screen, each action with its result, final outcome.
    var flowNote: String = ""
    var startedAt: Date?
    var endedAt: Date?
    var run: TestRunRecord?
    @Relationship(deleteRule: .cascade, inverse: \TestStepResult.caseRun)
    var steps: [TestStepResult] = []
    @Relationship(deleteRule: .cascade, inverse: \EvidenceRecord.caseRun)
    var evidence: [EvidenceRecord] = []

    init(caseID: String, title: String, category: String) {
        self.caseID = caseID; self.title = title; self.category = category
    }

    var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .notRun }
        set { statusRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        guard let startedAt, let endedAt else { return 0 }
        return endedAt.timeIntervalSince(startedAt)
    }
}

@Model final class TestStepResult {
    var index: Int = 0
    var actionID: String = ""
    var actionType: String = ""
    var actionSummary: String = ""
    var statusRaw: String = ExecutionStatus.notRun.rawValue
    var expected: String = ""
    var actual: String = ""
    var message: String = ""
    var startedAt: Date = Date()
    var duration: Double = 0
    var locatorUsed: String?
    var aiSuggestedLocator: Bool = false
    var screenshotPath: String?
    var caseRun: TestCaseRunRecord?

    init(index: Int, actionID: String, actionType: String, actionSummary: String) {
        self.index = index; self.actionID = actionID; self.actionType = actionType; self.actionSummary = actionSummary
    }

    var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .notRun }
        set { statusRaw = newValue.rawValue }
    }
}

@Model final class EvidenceRecord {
    var path: String = ""
    var kind: String = "screenshot"
    var createdAt: Date = Date()
    var caseRun: TestCaseRunRecord?

    init(path: String, kind: String) { self.path = path; self.kind = kind }
}

/// A route to a screen that was verified on a real run (learned once, replayed on later issues without reading the code).
@Model final class FlowRecord {
    var id: UUID = UUID()
    var projectPath: String = ""
    var scheme: String = ""
    var goal: String = ""
    /// Other texts the screen is shown with (localised titles), used to match later issues and to verify arrival.
    var aliases: [String] = []
    /// Elements tapped from the app's launch screen, in order. Taps only — never typed text.
    var steps: [String] = []
    var sourceIssueURL: String = ""
    var learnedAt: Date = Date()
    var lastUsedAt: Date?
    var successCount: Int = 0
    var failureCount: Int = 0
    /// A replay failed: do not trust it; the next run explores again and overwrites it.
    var stale: Bool = false

    init(projectPath: String, scheme: String, goal: String, aliases: [String], steps: [String], sourceIssueURL: String) {
        self.projectPath = projectPath; self.scheme = scheme; self.goal = goal
        self.aliases = aliases; self.steps = steps; self.sourceIssueURL = sourceIssueURL
    }
}

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        QAProject.self, GitHubIssueRecord.self, GeneratedTestCase.self, TestPlanRecord.self,
        SourceProjectRecord.self, BuildRecord.self, TestRunRecord.self, TestCaseRunRecord.self,
        TestStepResult.self, EvidenceRecord.self, FlowRecord.self,
    ]

    static func makeContainer() -> ModelContainer {
        let schema = Schema(PersistenceSchema.models)
        let storeURL = AppPaths.support.appendingPathComponent("AIQATestStudio.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fall back to in-memory so the app still launches; the UI shows a warning via AppState.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }
}
