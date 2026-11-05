import Foundation

struct ChecklistItem: Codable, Hashable, Identifiable, Sendable {
    var id: String            // CL-1, CL-2 ...
    var text: String
    var isChecked: Bool       // original state on GitHub (metadata only, never written back)
    var section: String?
    var line: Int
    var source: String        // "description" or "comment by <user>"
    var sourceURL: String     // link back to the issue / comment
    /// For structured test items (手順 / 期待結果 …) written in the issue: the author's own steps and expected result.
    var providedSteps: String? = nil
    var providedExpected: String? = nil
}

struct RequirementItem: Codable, Hashable, Identifiable, Sendable {
    var id: String            // REQ-1 ...
    var text: String
    var section: String
    var kind: String          // acceptance | requirement | expectation
}

struct IssueComment: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var author: String
    var isBot: Bool
    var body: String
    var createdAt: Date
    var url: String
}

struct IssueSnapshot: Codable, Sendable {
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var body: String
    var state: String
    var htmlURL: String
    var labels: [String]
    var updatedAt: Date
    var fetchedAt: Date
    var comments: [IssueComment]
    var checklist: [ChecklistItem]
    var requirements: [RequirementItem]
    var contentHash: String

    var reference: String { "\(owner)/\(repo)#\(number)" }
}

struct GitHubIssueRef: Hashable, Sendable {
    var owner: String
    var repo: String
    var number: Int
    var url: String { "https://github.com/\(owner)/\(repo)/issues/\(number)" }
}
