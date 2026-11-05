import Foundation

/// Pure helpers behind the test-case editor: keep ids, readiness and notes consistent after a manual edit.
enum CaseEditing {
    static func nextID(in cases: [PlannedCase]) -> String {
        let numbers = cases.compactMap { Int($0.id.split(separator: "-").last ?? "") }
        return String(format: "TC-%03d", (numbers.max() ?? 0) + 1)
    }

    static func blankAction(_ type: ActionType, caseID: String) -> TestAction {
        TestAction(id: "", type: type, target: type.needsTarget ? Locator(strategy: .label, value: "") : nil, fallbackTargets: [],
                   arguments: [:], timeoutSeconds: type.defaultTimeout, expectedOutcome: "", sourceTestCaseID: caseID)
    }

    static func newCase(id: String) -> PlannedCase {
        let draft = TestCaseDraft(id: id, title: "Test case mới", description: "", category: .original, preconditions: [],
                                  steps: [], testData: [], expectedResults: [], priority: .medium,
                                  sourceChecklistRef: nil, sourceRequirementRef: nil, readiness: .needsReview,
                                  reviewReason: nil, actions: [])
        var planned = PlannedCase(draft: draft, actions: [blankAction(.relaunchApp, caseID: id)], readiness: .needsReview, notes: [])
        normalize(&planned)
        return planned
    }

    /// Re-numbers action ids, then recomputes readiness and notes from the actual content.
    static func normalize(_ planned: inout PlannedCase) {
        let caseID = planned.draft.id
        for index in planned.actions.indices {
            planned.actions[index].id = "\(caseID)-A\(String(format: "%02d", index + 1))"
            planned.actions[index].sourceTestCaseID = caseID
        }
        planned.notes = problems(in: planned.actions)
        planned.readiness = planned.notes.isEmpty ? .ready : .needsReview
    }

    static func problems(in actions: [TestAction]) -> [String] {
        var notes: [String] = []
        for action in actions {
            if action.type.needsTarget, (action.target?.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                notes.append("\(action.id) (\(action.type.rawValue)) chưa có locator.")
            }
            if action.type == .typeText, (action.arguments["text"] ?? "").isEmpty { notes.append("\(action.id) chưa có text để nhập.") }
            if [.swipe, .scroll].contains(action.type), (action.arguments["direction"] ?? "").isEmpty {
                notes.append("\(action.id) chưa có hướng (up/down/left/right).")
            }
        }
        if !actions.contains(where: { $0.type.isAssertion }) { notes.append("Chưa có bước kiểm tra (assert): case không thể Pass.") }
        return notes
    }
}
