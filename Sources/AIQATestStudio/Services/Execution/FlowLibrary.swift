import Foundation
import SwiftData

/// Verified routes to screens, learned from real runs. Looked up before any source analysis or AI exploration.
@MainActor
struct FlowLibrary {
    let context: ModelContext

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Latest trusted flow for this project + scheme whose goal (or one of its localised aliases) matches.
    func find(projectPath: String, scheme: String, goal: String, aliases: [String] = []) -> FlowRecord? {
        let wanted = Set(([goal] + aliases).map(normalized).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<FlowRecord>(sortBy: [SortDescriptor(\.learnedAt, order: .reverse)]))) ?? []
        return all.first { record in
            record.projectPath == projectPath && record.scheme == scheme && !record.stale
                && !wanted.isDisjoint(with: Set(([record.goal] + record.aliases).map(normalized)))
        }
    }

    /// Stores (or replaces) the flow after a verified arrival.
    func learn(projectPath: String, scheme: String, goal: String, aliases: [String], steps: [String], issueURL: String) {
        let all = (try? context.fetch(FetchDescriptor<FlowRecord>())) ?? []
        for old in all where old.projectPath == projectPath && old.scheme == scheme && normalized(old.goal) == normalized(goal) {
            context.delete(old)
        }
        let record = FlowRecord(projectPath: projectPath, scheme: scheme, goal: goal, aliases: aliases, steps: steps, sourceIssueURL: issueURL)
        record.successCount = 1
        record.lastUsedAt = Date()
        context.insert(record)
        try? context.save()
    }

    func recordSuccess(_ record: FlowRecord) {
        record.successCount += 1; record.lastUsedAt = Date()
        try? context.save()
    }

    func recordFailure(_ record: FlowRecord) {
        record.failureCount += 1; record.stale = true
        try? context.save()
    }
}
