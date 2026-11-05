import Foundation

// MARK: - Approved action schema (the ONLY things a test plan may do)

enum ActionType: String, Codable, CaseIterable, Sendable {
    case launchApp, tap, typeText, clearText, swipe, scroll, waitForElement
    case assertVisible, assertNotVisible, assertText, assertEnabled, assertDisabled
    case takeScreenshot, relaunchApp, goBack

    var needsTarget: Bool {
        switch self {
        case .tap, .typeText, .clearText, .waitForElement, .assertVisible, .assertNotVisible,
             .assertText, .assertEnabled, .assertDisabled: return true
        default: return false
        }
    }

    var isAssertion: Bool {
        switch self {
        case .assertVisible, .assertNotVisible, .assertText, .assertEnabled, .assertDisabled: return true
        default: return false
        }
    }

    var defaultTimeout: Double {
        switch self {
        case .launchApp, .relaunchApp: return 20
        case .waitForElement: return 15
        case .tap, .typeText, .clearText: return 10
        case .assertVisible, .assertNotVisible, .assertText, .assertEnabled, .assertDisabled: return 8
        case .swipe, .scroll, .goBack, .takeScreenshot: return 5
        }
    }
}

/// Locator strategies in preferred order: identifier > label/name > type + deterministic attribute.
enum LocatorStrategy: String, Codable, CaseIterable, Sendable {
    case accessibilityId, label, name, typeAndAttribute
    /// Regular expression matched against the whole label (e.g. a price like `JPY7,684` whose digits are unknown in advance).
    case labelMatches

    var rank: Int {
        switch self {
        case .accessibilityId: return 0
        case .label: return 1
        case .name: return 2
        case .labelMatches: return 2
        case .typeAndAttribute: return 3
        }
    }
}

struct Locator: Codable, Hashable, Sendable {
    var strategy: LocatorStrategy
    /// identifier / label / name / attribute text
    var value: String
    /// Required for `.typeAndAttribute`, e.g. `XCUIElementTypeButton`.
    var elementType: String?

    var summary: String {
        switch strategy {
        case .accessibilityId: return "id=\(value)"
        case .label: return "label=\(value)"
        case .name: return "name=\(value)"
        case .labelMatches: return "label~\(value)"
        case .typeAndAttribute: return "\(elementType ?? "?")[\(value)]"
        }
    }
}

enum CaseCategory: String, Codable, Sendable {
    case original, suggested
    var title: String { self == .original ? "Original" : "AI Suggested" }
}

enum CasePriority: String, Codable, CaseIterable, Sendable { case high, medium, low }

enum Readiness: String, Codable, Sendable {
    case ready, needsReview, needsTestData
    var title: String {
        switch self {
        case .ready: return "Ready"
        case .needsReview: return "Needs Review"
        case .needsTestData: return "Needs Test Data"
        }
    }
}

struct TestDataItem: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var description: String
    var value: String?
    var id: String { name }
    var isMissing: Bool { (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - AI output (strictly decoded)

struct ActionDraft: Codable, Hashable, Sendable {
    var type: ActionType
    var target: Locator?
    var fallbackTargets: [Locator]
    var arguments: [String: String]
    var timeoutSeconds: Double?
    var expectedOutcome: String

    enum CodingKeys: String, CodingKey { case type, target, fallbackTargets, arguments, timeoutSeconds, expectedOutcome }

    init(type: ActionType, target: Locator? = nil, fallbackTargets: [Locator] = [], arguments: [String: String] = [:],
         timeoutSeconds: Double? = nil, expectedOutcome: String = "") {
        self.type = type; self.target = target; self.fallbackTargets = fallbackTargets
        self.arguments = arguments; self.timeoutSeconds = timeoutSeconds; self.expectedOutcome = expectedOutcome
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(ActionType.self, forKey: .type)
        target = try c.decodeIfPresent(Locator.self, forKey: .target)
        fallbackTargets = try c.decodeIfPresent([Locator].self, forKey: .fallbackTargets) ?? []
        arguments = try c.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        expectedOutcome = try c.decodeIfPresent(String.self, forKey: .expectedOutcome) ?? ""
    }
}

struct TestCaseDraft: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    var category: CaseCategory
    var preconditions: [String]
    var steps: [String]
    var testData: [TestDataItem]
    var expectedResults: [String]
    var priority: CasePriority
    var sourceChecklistRef: String?
    var sourceRequirementRef: String?
    var readiness: Readiness
    var reviewReason: String?
    var actions: [ActionDraft]
}

extension TestCaseDraft {
    enum CodingKeys: String, CodingKey {
        case id, title, description, category, preconditions, steps, testData, expectedResults, priority
        case sourceChecklistRef, sourceRequirementRef, readiness, reviewReason, actions
    }

    /// Only structurally essential fields are required; the compact AI schema omits the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try c.decode(CaseCategory.self, forKey: .category)
        preconditions = try c.decodeIfPresent([String].self, forKey: .preconditions) ?? []
        steps = try c.decode([String].self, forKey: .steps)
        testData = try c.decodeIfPresent([TestDataItem].self, forKey: .testData) ?? []
        expectedResults = try c.decode([String].self, forKey: .expectedResults)
        priority = try c.decodeIfPresent(CasePriority.self, forKey: .priority) ?? .medium
        sourceChecklistRef = try c.decodeIfPresent(String.self, forKey: .sourceChecklistRef)
        sourceRequirementRef = try c.decodeIfPresent(String.self, forKey: .sourceRequirementRef)
        readiness = try c.decode(Readiness.self, forKey: .readiness)
        reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason)
        actions = try c.decode([ActionDraft].self, forKey: .actions)
    }
}

struct AIResponse: Codable, Sendable {
    var testCases: [TestCaseDraft]
}

// MARK: - Executable plan

struct TestAction: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: ActionType
    var target: Locator?
    var fallbackTargets: [Locator]
    var arguments: [String: String]
    var timeoutSeconds: Double
    var expectedOutcome: String
    var sourceTestCaseID: String

    var allLocators: [Locator] { (target.map { [$0] } ?? []) + fallbackTargets }

    var summary: String {
        var parts = [type.rawValue]
        if let target { parts.append(target.summary) }
        if let text = arguments["text"] ?? arguments["expectedText"] ?? arguments["direction"] { parts.append("\"\(text)\"") }
        return parts.joined(separator: " ")
    }
}

struct PlannedCase: Codable, Hashable, Identifiable, Sendable {
    var draft: TestCaseDraft
    var actions: [TestAction]
    var readiness: Readiness
    var notes: [String]
    /// User confirmed the case may be executed although it was flagged Needs Review.
    var approved: Bool = false

    var id: String { draft.id }
    var missingTestData: [TestDataItem] { draft.testData.filter(\.isMissing) }

    var effectiveReadiness: Readiness {
        if !missingTestData.isEmpty { return .needsTestData }
        if readiness == .needsTestData { return approved ? .ready : .needsReview }
        return approved ? .ready : readiness
    }

    var testDataValues: [String: String] {
        Dictionary(draft.testData.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}

struct TestPlan: Codable, Sendable {
    var version: Int
    var createdAt: Date
    var issueURL: String
    var issueHash: String
    var model: String
    var cases: [PlannedCase]
}
