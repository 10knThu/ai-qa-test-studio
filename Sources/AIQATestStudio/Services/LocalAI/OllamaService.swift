import Foundation

struct OllamaModel: Identifiable, Hashable, Sendable {
    let name: String
    let sizeBytes: Int64
    let parameterSize: String?
    let quantization: String?
    var id: String { name }
    var detail: String {
        [parameterSize, quantization, ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Talks to a local Ollama server only. There is intentionally no cloud fallback.
final class OllamaService {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = Prefs.ollamaURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 900   // local inference on small machines can be slow
        config.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: config)
    }

    static var setupInstructions: String {
        "Install Ollama from https://ollama.com, start it (`ollama serve`) and pull a model, e.g. `ollama pull \(recommendedModelHint)`."
    }

    /// Smaller quantised models on machines with limited RAM.
    static var recommendedModelHint: String {
        ProcessInfo.processInfo.physicalMemory < 16 * 1024 * 1024 * 1024 ? "qwen2.5:3b-instruct" : "qwen2.5:7b-instruct"
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "HTTP \(http.statusCode)"
                if http.statusCode == 404 {
                    throw AppError("Ollama model not found: \(message)", recovery: "Pull it with `ollama pull <model>` or choose an installed model in Settings.")
                }
                throw AppError("Ollama error: \(message)")
            }
            return data
        } catch let error as URLError {
            throw AppError("Ollama is not reachable at \(baseURL.absoluteString) (\(error.localizedDescription)).", recovery: Self.setupInstructions)
        }
    }

    func version() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 5
        let data = try await send(request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String ?? "unknown"
    }

    func models() async throws -> [OllamaModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 10
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let details = entry["details"] as? [String: Any]
            return OllamaModel(name: name, sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                               parameterSize: details?["parameter_size"] as? String,
                               quantization: details?["quantization_level"] as? String)
        }.filter { !$0.name.localizedCaseInsensitiveContains("embed") }
    }

    private func chatRequest(model: String, system: String, user: String, schema: [String: Any], stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": stream,
            "format": schema,
            "keep_alive": "2m",   // short: a 7B model holds ~5 GB RAM and CPU; release it soon after the last batch
            "options": ["temperature": 0, "num_ctx": 6144],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Chat completion constrained to `schema` using Ollama's structured outputs.
    func chat(model: String, system: String, user: String, schema: [String: Any]) async throws -> String {
        let data = try await send(try chatRequest(model: model, system: system, user: user, schema: schema, stream: false))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AppError("Ollama returned an unexpected response.")
        }
        return content
    }

    /// Same as `chat` but streams tokens; `onContent` receives each new fragment. Returns the full text.
    func chatStream(model: String, system: String, user: String, schema: [String: Any],
                    onContent: (String) async -> Void) async throws -> String {
        let request = try chatRequest(model: model, system: system, user: user, schema: schema, stream: true)
        var full = ""
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines { body += line }
                let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String ?? "HTTP \(http.statusCode)"
                if http.statusCode == 404 {
                    throw AppError("Ollama model not found: \(message)", recovery: "Pull it with `ollama pull <model>` or choose an installed model in Settings.")
                }
                throw AppError("Ollama error: \(message)")
            }
            for try await line in bytes.lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let error = object["error"] as? String { throw AppError("Ollama error: \(error)") }
                if let content = (object["message"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                    full += content
                    await onContent(content)
                }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AppError("Ollama is not reachable at \(baseURL.absoluteString) (\(error.localizedDescription)).", recovery: Self.setupInstructions)
        }
        return full
    }
}

/// Incrementally extracts complete test-case objects from the streamed `{"testCases":[ {...}, {...} ]}` JSON.
struct CaseStreamParser {
    private var bytes: [UInt8] = []
    private var scanned = 0
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var start = 0

    mutating func feed(_ text: String) -> [Data] {
        bytes.append(contentsOf: text.utf8)
        var completed: [Data] = []
        while scanned < bytes.count {
            let byte = bytes[scanned]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x7B, 0x5B:
                    depth += 1
                    if byte == 0x7B && depth == 3 { start = scanned }   // root { → 1, testCases [ → 2, case { → 3
                case 0x7D, 0x5D:
                    if byte == 0x7D && depth == 3 { completed.append(Data(bytes[start...scanned])) }
                    depth -= 1
                default: break
                }
            }
            scanned += 1
        }
        return completed
    }
}
