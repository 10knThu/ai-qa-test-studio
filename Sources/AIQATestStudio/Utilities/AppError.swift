import Foundation

/// An actionable error: what went wrong + how to recover.
struct AppError: LocalizedError {
    let message: String
    let recovery: String?

    init(_ message: String, recovery: String? = nil) {
        self.message = message
        self.recovery = recovery
    }

    var errorDescription: String? { message }
    var recoverySuggestion: String? { recovery }
}

extension Error {
    /// Text suitable for showing to the user (message + recovery instructions).
    var userText: String {
        if self is CancellationError { return "Cancelled by user." }
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            if let recovery = localized.recoverySuggestion { return "\(description)\n\nHow to fix: \(recovery)" }
            return description
        }
        return localizedDescription
    }
}

extension String {
    /// Last `count` non-empty lines, used to summarise tool output in errors.
    func tailLines(_ count: Int) -> String {
        let lines = split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }
}

enum JSONExtract {
    /// Tools such as xcodebuild may print warnings around their JSON. Return only the JSON payload.
    static func payload(from text: String) -> Data? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let closer: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: closer), end >= start else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
