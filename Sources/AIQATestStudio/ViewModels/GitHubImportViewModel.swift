import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class GitHubImportViewModel {
    private let context: ModelContext
    private let service = GitHubIssueService()

    var tokenInput = ""
    var isConnected = false
    var tokenStatus = "Not connected — public repositories only (60 requests/hour)"
    var isCheckingToken = false

    var urlInput = ""
    var snapshot: IssueSnapshot?
    var revision = 1
    var isFetching = false
    var error: String?
    var changeNotice: String?
    var appContext = ""
    /// Checklist items the user unticked — they are left out of AI analysis (saves generation time).
    var excluded: Set<String> = []

    /// "Definition of done" checkboxes (e.g. “実装が完了している”) are process items, not UI tests: unticked by default.
    private func applyDefaultExclusions() {
        let keywords = ["完了条件", "definition of done", "điều kiện hoàn thành", "dod"]
        excluded = Set((snapshot?.checklist ?? []).filter { item in
            guard let section = item.section?.lowercased() else { return false }
            return keywords.contains { section.contains($0) }
        }.map(\.id))
    }

    var analysisSnapshot: IssueSnapshot? {
        guard var copy = snapshot else { return nil }
        copy.checklist = copy.checklist.filter { !excluded.contains($0.id) }
        return copy
    }

    init(context: ModelContext) {
        self.context = context
        if KeychainStore.loadToken() != nil {
            isConnected = true
            tokenStatus = "Connected — token stored in macOS Keychain"
        }
    }

    // MARK: Token

    func connect() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isCheckingToken = true
        defer { isCheckingToken = false }
        do {
            let message = try await service.validateToken(token)
            try KeychainStore.saveToken(token)
            tokenInput = ""
            isConnected = true
            tokenStatus = "Connected — \(message). Stored in macOS Keychain."
            error = nil
        } catch {
            isConnected = false
            tokenStatus = error.userText
        }
    }

    func disconnect() {
        KeychainStore.deleteToken()
        isConnected = false
        tokenStatus = "Not connected — public repositories only (60 requests/hour)"
    }

    // MARK: Fetch (read-only)

    func fetch() async {
        error = nil
        changeNotice = nil
        let ref: GitHubIssueRef
        do { ref = try GitHubIssueService.parse(urlInput) } catch { self.error = error.userText; return }

        isFetching = true
        defer { isFetching = false }
        do {
            let fresh = try await service.fetch(ref, token: KeychainStore.loadToken())
            store(fresh, ref: ref)
        } catch {
            if let cached = loadCached(ref.url) {
                snapshot = cached.snapshot
                revision = cached.revision
                self.error = error.userText
                changeNotice = "Showing the cached copy imported \(cached.snapshot.fetchedAt.formatted()) because GitHub could not be reached."
            } else {
                self.error = error.userText
            }
        }
    }

    /// Re-fetches the current issue and reports whether it was edited after import.
    func checkForChanges() async {
        guard let current = snapshot else { return }
        let ref = GitHubIssueRef(owner: current.owner, repo: current.repo, number: current.number)
        do {
            let fresh = try await service.fetch(ref, token: KeychainStore.loadToken())
            if fresh.contentHash != current.contentHash {
                changeNotice = "The issue was edited on GitHub since it was imported (\(fresh.updatedAt.formatted())). Re-import to regenerate test cases."
            } else {
                changeNotice = "No changes since import."
            }
        } catch {
            changeNotice = "Could not check for changes: \(error.userText)"
        }
    }

    private func store(_ fresh: IssueSnapshot, ref: GitHubIssueRef) {
        let url = ref.url
        let existing = try? context.fetch(FetchDescriptor<GitHubIssueRecord>(predicate: #Predicate { $0.url == url })).first
        let data = (try? Self.encoder.encode(fresh)) ?? Data()
        if let record = existing {
            if record.contentHash != fresh.contentHash {
                record.revision += 1
                changeNotice = "Issue changed since the previous import — now revision \(record.revision). Previously generated test cases may be outdated."
            }
            record.title = fresh.title; record.snapshotJSON = data; record.contentHash = fresh.contentHash
            record.issueUpdatedAt = fresh.updatedAt; record.fetchedAt = Date()
            revision = record.revision
        } else {
            let record = GitHubIssueRecord(url: url, owner: ref.owner, repo: ref.repo, number: ref.number, title: fresh.title,
                                           snapshotJSON: data, contentHash: fresh.contentHash, issueUpdatedAt: fresh.updatedAt)
            context.insert(record)
            revision = 1
        }
        try? context.save()
        snapshot = fresh
        applyDefaultExclusions()
    }

    /// Clears the current issue so a new URL can be imported (history is kept).
    func reset() {
        excluded = []; snapshot = nil; urlInput = ""; error = nil; changeNotice = nil; appContext = ""; revision = 1
    }

    /// Shows an issue from local history (no network call).
    func load(_ record: GitHubIssueRecord) {
        guard let loaded = try? Self.decoder.decode(IssueSnapshot.self, from: record.snapshotJSON) else {
            error = "The cached copy of this issue is unreadable. Fetch it again."
            return
        }
        snapshot = loaded
        applyDefaultExclusions()
        revision = record.revision
        urlInput = record.url
        error = nil
        changeNotice = "Loaded from history (imported \(record.fetchedAt.formatted())). Use “Check for changes” to compare with GitHub."
    }

    private func loadCached(_ url: String) -> (snapshot: IssueSnapshot, revision: Int)? {
        guard let record = try? context.fetch(FetchDescriptor<GitHubIssueRecord>(predicate: #Predicate { $0.url == url })).first,
              let snapshot = try? Self.decoder.decode(IssueSnapshot.self, from: record.snapshotJSON) else { return nil }
        return (snapshot, record.revision)
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
