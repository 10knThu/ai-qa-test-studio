import Foundation
import CryptoKit

/// Read-only GitHub client. Only HTTP GET is ever issued; nothing is written back to GitHub.
final class GitHubIssueService {
    private let session: URLSession
    private let apiBase = URL(string: "https://api.github.com")!

    init(session: URLSession = .shared) { self.session = session }

    // MARK: URL parsing

    static func parse(_ text: String) throws -> GitHubIssueRef {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = AppError("“\(trimmed)” is not a valid GitHub Issue URL.",
                               recovery: "Use the form https://github.com/OWNER/REPOSITORY/issues/123")
        guard let url = URL(string: trimmed), url.scheme == "https",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { throw invalid }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "issues", let number = Int(parts[3]), number > 0 else {
            if parts.count >= 4, parts[2] == "pull" {
                throw AppError("This is a pull request URL, not an issue.", recovery: "Paste an Issue URL (…/issues/123).")
            }
            throw invalid
        }
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [parts[0], parts[1]].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(valid.contains) }) else { throw invalid }
        return GitHubIssueRef(owner: parts[0], repo: parts[1], number: number)
    }

    // MARK: Requests (GET only)

    private func get(_ path: String, query: [URLQueryItem] = [], token: String?) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AIQATestStudio", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch let error as URLError {
            throw AppError("Could not reach GitHub: \(error.localizedDescription)", recovery: "Check your internet connection.")
        }
        guard let http = response as? HTTPURLResponse else { throw AppError("Unexpected response from GitHub.") }
        try Self.check(http, data: data, hasToken: !(token ?? "").isEmpty)
        return (data, http)
    }

    static func check(_ http: HTTPURLResponse, data: Data, hasToken: Bool) throws {
        switch http.statusCode {
        case 200..<300: return
        case 401:
            throw AppError("GitHub rejected the token (401).",
                           recovery: "Create a new fine-grained personal access token with read-only “Issues” permission and reconnect.")
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 {
                var reset = ""
                if let value = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let epoch = TimeInterval(value) {
                    reset = " Limit resets at \(Date(timeIntervalSince1970: epoch).formatted(date: .omitted, time: .shortened))."
                }
                throw AppError("GitHub API rate limit reached.\(reset)",
                               recovery: hasToken ? "Wait for the limit to reset." : "Connect a token to raise the limit from 60 to 5,000 requests/hour.")
            }
            throw AppError("Access to this repository is forbidden (403).",
                           recovery: "Grant the token read access to this repository's Issues, or check SSO authorization for the organization.")
        case 404:
            throw AppError("Issue not found (404).",
                           recovery: hasToken ? "Check the URL, and that the token's repository access includes this private repository."
                                              : "If the repository is private, connect a token with read access to its Issues.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw AppError("GitHub returned an error: \(message)")
        }
    }

    func validateToken(_ token: String) async throws -> String {
        let (data, _) = try await get("rate_limit", token: token)
        let remaining = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["rate"] as? [String: Any])?["remaining"] as? Int
        return "Token accepted" + (remaining.map { " — \($0) API calls remaining this hour" } ?? "")
    }

    // MARK: Fetch

    private struct APIIssue: Decodable {
        struct Label: Decodable { let name: String }
        let number: Int
        let title: String
        let body: String?
        let state: String
        let html_url: String
        let updated_at: Date
        let labels: [Label]
        let pull_request: [String: String?]?
    }

    private struct APIComment: Decodable {
        struct User: Decodable { let login: String; let type: String? }
        let id: Int
        let body: String?
        let html_url: String
        let created_at: Date
        let user: User?
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func fetch(_ ref: GitHubIssueRef, token: String?) async throws -> IssueSnapshot {
        let base = "repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)"
        let (issueData, _) = try await get(base, token: token)
        let issue = try Self.decoder.decode(APIIssue.self, from: issueData)
        if issue.pull_request != nil {
            throw AppError("#\(ref.number) is a pull request.", recovery: "Paste a GitHub Issue URL instead.")
        }

        var comments: [APIComment] = []
        var page = 1
        while page <= 30 {
            let (data, _) = try await get(base + "/comments",
                                          query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))],
                                          token: token)
            let batch = try Self.decoder.decode([APIComment].self, from: data)
            comments += batch
            if batch.count < 100 { break }
            page += 1
        }

        return Self.makeSnapshot(ref: ref, issue: issue, comments: comments)
    }

    private static func makeSnapshot(ref: GitHubIssueRef, issue: APIIssue, comments apiComments: [APIComment]) -> IssueSnapshot {
        let body = issue.body ?? ""
        let comments = apiComments.map {
            IssueComment(id: $0.id, author: $0.user?.login ?? "unknown", isBot: $0.user?.type == "Bot",
                         body: $0.body ?? "", createdAt: $0.created_at, url: $0.html_url)
        }

        var checklist: [ChecklistItem] = []
        func add(_ raws: [IssueMarkdownParser.RawChecklist], source: String, url: String) {
            for raw in raws {
                checklist.append(ChecklistItem(id: "CL-\(checklist.count + 1)", text: raw.text, isChecked: raw.checked,
                                               section: raw.section, line: raw.line, source: source, sourceURL: url,
                                               providedSteps: raw.steps, providedExpected: raw.expected))
            }
        }
        /// Checkbox items + structured test items. Returns whether structured items were found.
        @discardableResult
        func collect(_ markdown: String, source: String, url: String) -> Bool {
            add(IssueMarkdownParser.checklist(from: markdown), source: source, url: url)
            let structured = IssueMarkdownParser.testItems(from: markdown)
            add(structured, source: source, url: url)
            return !structured.isEmpty
        }
        let bodyHasTestItems = collect(body, source: "description", url: issue.html_url)
        for comment in comments where !comment.isBot {
            collect(comment.body, source: "comment by \(comment.author)", url: comment.url)
        }

        var requirements: [RequirementItem] = []
        // When the author already wrote explicit test items, headings like "テスト項目" would only add noise.
        if !bodyHasTestItems {
            for raw in IssueMarkdownParser.requirements(from: body) {
                requirements.append(RequirementItem(id: "REQ-\(requirements.count + 1)", text: raw.text, section: raw.section, kind: raw.kind))
            }
        }

        return IssueSnapshot(owner: ref.owner, repo: ref.repo, number: ref.number, title: issue.title, body: body,
                             state: issue.state, htmlURL: issue.html_url, labels: issue.labels.map(\.name),
                             updatedAt: issue.updated_at, fetchedAt: Date(), comments: comments, checklist: checklist,
                             requirements: requirements, contentHash: hash(title: issue.title, body: body, state: issue.state, comments: comments))
    }

    /// Hash of everything that influences generated tests; used to detect edits after import.
    static func hash(title: String, body: String, state: String, comments: [IssueComment]) -> String {
        var text = title + "\u{0}" + body + "\u{0}" + state
        for comment in comments { text += "\u{0}\(comment.id):\(comment.body)" }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
