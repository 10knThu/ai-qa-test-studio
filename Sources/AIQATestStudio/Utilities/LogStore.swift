import Foundation
import Observation

/// Observable, size-capped log buffer for SwiftUI. Full logs are also streamed to a file.
@MainActor
@Observable
final class LogStore {
    enum Level { case info, warning, error, success }

    struct Line: Identifiable {
        let id: Int
        let text: String
        let level: Level
    }

    private(set) var lines: [Line] = []
    private(set) var fileURL: URL?

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var pending: [Line] = []
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let maxLines = 5000
    /// Called (on the main actor) for every appended line, e.g. to derive the current build step.
    @ObservationIgnored var onLine: ((String) -> Void)?
    @ObservationIgnored private var flushScheduled = false

    func clear() {
        lines.removeAll()
        pending.removeAll()
        nextID = 0
    }

    /// Starts mirroring every appended line to `url` (full, uncapped log).
    func startFile(_ url: URL) {
        try? handle?.close()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
    }

    func closeFile() {
        try? handle?.close()
        handle = nil
    }

    func append(_ text: String, level: Level? = nil) {
        let resolved = level ?? Self.classify(text)
        pending.append(Line(id: nextID, text: text, level: resolved))
        nextID += 1
        if let data = (text + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
        onLine?(text)
        if Date().timeIntervalSince(lastFlush) > 0.1 {
            flush()
        } else if !flushScheduled {
            // Trailing flush: lines appended in a burst must still appear even if nothing else follows.
            flushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll()
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lastFlush = Date()
    }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// Runs `body`, delivering each emitted line to this store in order.
    func capture<T>(_ body: (@escaping @Sendable (String) -> Void) async throws -> T) async throws -> T {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor in
            for await line in stream { self.append(line) }
        }
        do {
            let result = try await body { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            flush()
            return result
        } catch {
            continuation.finish()
            await consumer.value
            flush()
            throw error
        }
    }

    static func classify(_ text: String) -> Level {
        if text.contains("error:") || text.contains("** BUILD FAILED **") { return .error }
        if text.contains("warning:") { return .warning }
        if text.contains("** BUILD SUCCEEDED **") { return .success }
        return .info
    }
}
