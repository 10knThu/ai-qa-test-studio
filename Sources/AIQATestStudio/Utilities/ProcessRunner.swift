import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    /// stdout (+ stderr when merged).
    let output: String
    /// stderr only when `mergeStderr` is false.
    let errorOutput: String
    var succeeded: Bool { exitCode == 0 }
}

/// Splits a byte stream into lines (thread-safe) and optionally collects everything.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var collected = Data()
    private let collect: Bool
    private let onLine: (@Sendable (String) -> Void)?

    init(collect: Bool, onLine: (@Sendable (String) -> Void)?) {
        self.collect = collect
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        if collect { collected.append(data) }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Runs external tools with Foundation.Process. Arguments are passed as an array (never through a shell).
enum ProcessRunner {
    static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        mergeStderr: Bool = true,
        collectOutput: Bool = true,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath + ":" + (env["PATH"] ?? "")
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = mergeStderr ? outPipe : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outSplitter = LineSplitter(collect: collectOutput, onLine: onLine)
        let errSplitter = LineSplitter(collect: true, onLine: mergeStderr ? nil : onLine)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { outSplitter.feed(data) }
        }
        if !mergeStderr {
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errSplitter.feed(data) }
            }
        }

        let box = ProcessBox(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { outSplitter.feed(rest) }
        outSplitter.flush()
        if !mergeStderr {
            errPipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { errSplitter.feed(rest) }
            errSplitter.flush()
        }

        try Task.checkCancellation()
        return ProcessResult(exitCode: status, output: outSplitter.text, errorOutput: mergeStderr ? "" : errSplitter.text)
    }

    /// Runs a tool found on PATH (node, appium, ollama, ...).
    static func runTool(_ name: String, _ arguments: [String], mergeStderr: Bool = true) async throws -> ProcessResult {
        try await run("/usr/bin/env", [name] + arguments, mergeStderr: mergeStderr)
    }

    static func xcrun(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await run("/usr/bin/xcrun", arguments, onLine: onLine)
    }
}
