import Foundation
import SwiftUI

enum ExecutionStatus: String, Codable, CaseIterable, Sendable {
    case notRun, running, passed, failed, blocked, needsReview, skipped, cancelled

    var title: String {
        switch self {
        case .notRun: return "Not Run"
        case .running: return "Running"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .needsReview: return "Needs Review"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .notRun: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        case .blocked: return .orange
        case .needsReview: return .yellow
        case .skipped: return .gray
        case .cancelled: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .notRun: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        case .needsReview: return "questionmark.circle.fill"
        case .skipped: return "forward.circle"
        case .cancelled: return "stop.circle.fill"
        }
    }
}

/// Stage state for the Source → Build → Boot → Install → Launch pipeline.
enum StageState: Equatable {
    case idle, running(String), succeeded(String), failed(String), cancelled

    var isRunning: Bool { if case .running = self { return true } else { return false } }
    var isSucceeded: Bool { if case .succeeded = self { return true } else { return false } }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    var detail: String {
        switch self {
        case .idle: return "Not started"
        case .running(let text), .succeeded(let text), .failed(let text): return text
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Structured execution events (service → UI)

struct StepOutcome: Sendable {
    var caseID: String
    var action: TestAction
    var index: Int
    var status: ExecutionStatus
    var expected: String
    var actual: String
    var message: String
    var startedAt: Date
    var duration: TimeInterval
    var locatorUsed: String?
    var aiSuggestedLocator: Bool
    var screenshot: URL?
}

struct CaseOutcome: Sendable {
    var caseID: String
    var status: ExecutionStatus
    var message: String
    var startedAt: Date
    var endedAt: Date
    var assertionsExecuted: Int
}

enum ExecutionEvent: Sendable {
    case runStarted(total: Int)
    case caseStarted(caseID: String, totalActions: Int)
    case actionStarted(caseID: String, action: TestAction, index: Int)
    case log(String, level: LogLevel)
    case actionFinished(StepOutcome)
    case evidence(caseID: String, url: URL, kind: String)
    case caseFinished(CaseOutcome)
    case navigationPath(goal: String, path: [String], origin: NavigationOrigin)
    case flowStale(goal: String)
    case runFinished(infrastructureProblem: String?)
}

/// Where the route to the screen under test came from.
enum NavigationOrigin: String, Sendable {
    case stored, explored, alreadyThere

    var title: String {
        switch self {
        case .stored: return "Thư viện luồng (đã học, không cần đọc code)"
        case .explored: return "Khám phá mới (đọc source + UI thật)"
        case .alreadyThere: return "Đã ở sẵn màn hình đích"
        }
    }
}

enum LogLevel: Sendable { case info, warning, error, success }

/// Raised for environment problems (Appium/WDA/Simulator). Never converted into a test Failure.
struct InfrastructureFailure: Error, Sendable {
    var message: String
}
