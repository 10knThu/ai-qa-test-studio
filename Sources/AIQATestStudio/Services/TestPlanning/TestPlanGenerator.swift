import Foundation

/// Converts validated AI drafts into an executable, schema-limited action list.
struct TestPlanGenerator {

    static let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}"#)

    static func substitute(_ text: String, data: [String: String]) -> (text: String, missing: [String]) {
        var missing: [String] = []
        var result = text
        let matches = placeholderRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let full = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            if let value = data[name], !value.isEmpty {
                result.replaceSubrange(full, with: value)
            } else {
                missing.append(name)
            }
        }
        return (result, missing)
    }

    func generate(drafts: [TestCaseDraft], snapshot: IssueSnapshot, model: String, version: Int,
                  knownIdentifiers: Set<String>, fillMissing: Bool = true) -> TestPlan {
        var cases: [PlannedCase] = []
        var originalCounter = 0, suggestedCounter = 0

        // Guarantee every checklist item has an Original case, even when the model skipped one.
        var drafts = drafts
        let covered = Set(drafts.compactMap { $0.category == .original ? $0.sourceChecklistRef : nil })
        for item in snapshot.checklist where fillMissing && !covered.contains(item.id) {
            drafts.append(TestCaseDraft(
                id: "", title: item.text, description: "Checklist item \(item.id) from the issue.", category: .original,
                preconditions: [], steps: [item.text], testData: [], expectedResults: ["Not specified by the model — review required."],
                priority: .medium, sourceChecklistRef: item.id, sourceRequirementRef: nil, readiness: .needsReview,
                reviewReason: "The AI did not return a test case for this checklist item.", actions: []))
        }
        drafts.sort { ($0.category == .original ? 0 : 1) < ($1.category == .original ? 0 : 1) }

        for var draft in drafts {
            if draft.category == .original { originalCounter += 1; draft.id = String(format: "TC-%03d", originalCounter) }
            else { suggestedCounter += 1; draft.id = String(format: "TS-%03d", suggestedCounter) }

            var notes: [String] = []
            if let reason = draft.reviewReason, !reason.isEmpty { notes.append(reason) }
            var readiness = draft.readiness

            var actions = draft.actions.enumerated().map { index, action in
                Self.makeAction(action, id: "\(draft.id)-A\(String(format: "%02d", index + 1))", caseID: draft.id)
            }

            // Isolation: every case starts from a freshly launched app unless the plan says otherwise.
            if !actions.contains(where: { $0.type == .launchApp || $0.type == .relaunchApp }) {
                actions.insert(TestAction(id: "", type: .relaunchApp, target: nil, fallbackTargets: [], arguments: [:],
                                          timeoutSeconds: ActionType.relaunchApp.defaultTimeout,
                                          expectedOutcome: "App starts in a clean foreground state", sourceTestCaseID: draft.id), at: 0)
            }
            actions = actions.enumerated().map { index, action in
                var copy = action; copy.id = "\(draft.id)-A\(String(format: "%02d", index + 1))"; return copy
            }

            // "assertText" with no expected text on a label/name locator can only mean "an element with this text is shown".
            actions = actions.map { action in
                guard action.type == .assertText, (action.arguments["expectedText"] ?? action.arguments["text"] ?? "").isEmpty,
                      let target = action.target, target.strategy == .label || target.strategy == .name else { return action }
                var copy = action; copy.type = .assertVisible
                notes.append("\(action.id): assertText had no expected text; converted to assertVisible on “\(target.value)”.")
                return copy
            }
            for action in actions {
                if action.type.needsTarget && action.target == nil {
                    notes.append("\(action.id) (\(action.type.rawValue)) has no locator."); readiness = .needsReview
                }
                if action.type == .typeText && (action.arguments["text"] ?? "").isEmpty {
                    notes.append("\(action.id) types no text."); readiness = .needsReview
                }
                if action.type == .assertText && (action.arguments["expectedText"] ?? action.arguments["text"] ?? "").isEmpty {
                    notes.append("\(action.id) has no expected text."); readiness = .needsReview
                }
                if !knownIdentifiers.isEmpty, let target = action.target, target.strategy == .accessibilityId,
                   !knownIdentifiers.contains(target.value) {
                    notes.append("Identifier “\(target.value)” was not found in the source project — will be validated at run time.")
                }
            }
            if !actions.contains(where: { $0.type.isAssertion }) {
                notes.append("No assertion action: the case cannot be Passed without a verifiable check.")
                readiness = .needsReview
            }
            if draft.testData.contains(where: \.isMissing) && readiness == .ready { readiness = .needsTestData }

            cases.append(PlannedCase(draft: draft, actions: actions, readiness: readiness, notes: notes))
        }

        return TestPlan(version: version, createdAt: Date(), issueURL: snapshot.htmlURL, issueHash: snapshot.contentHash,
                        model: model, cases: cases)
    }

    static func makeAction(_ draft: ActionDraft, id: String, caseID: String) -> TestAction {
        // Fallback order: accessibility id → label/name → type + attribute. AI locators are only candidates.
        var locators = ((draft.target.map { [$0] } ?? []) + draft.fallbackTargets)
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        var seen = Set<Locator>()
        locators = locators.filter { seen.insert($0).inserted }.sorted { $0.strategy.rank < $1.strategy.rank }
        let timeout = min(max(draft.timeoutSeconds ?? draft.type.defaultTimeout, 1), 120)
        return TestAction(id: id, type: draft.type, target: locators.first, fallbackTargets: Array(locators.dropFirst()),
                          arguments: draft.arguments, timeoutSeconds: timeout, expectedOutcome: draft.expectedOutcome,
                          sourceTestCaseID: caseID)
    }
}
