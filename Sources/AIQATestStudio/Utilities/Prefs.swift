import Foundation
import CryptoKit

/// User defaults keys + defaults. Views use @AppStorage with the same keys.
enum Prefs {
    enum Key {
        static let ollamaURL = "ollamaURL"
        static let ollamaModel = "ollamaModel"
        static let appiumURL = "appiumURL"
        static let defaultSimulatorUDID = "defaultSimulatorUDID"
        static let evidenceDirectory = "evidenceDirectory"
        static let disableSigning = "disableCodeSigning"
        static let lastSourcePath = "lastSourcePath"
        static let lastSourceBookmark = "lastSourceBookmark"
    }

    static let defaultOllamaURL = "http://127.0.0.1:11434"
    static let defaultAppiumURL = "http://127.0.0.1:4723"
    /// iPhone 17 Pro (iOS 26.2) on the developer machine this project was written for.
    static let defaultSimulatorUDID = "8833CCD1-446C-4934-807A-8AAAD824559B"

    static var ollamaURL: URL {
        URL(string: UserDefaults.standard.string(forKey: Key.ollamaURL) ?? defaultOllamaURL) ?? URL(string: defaultOllamaURL)!
    }
    static var appiumURL: URL {
        URL(string: UserDefaults.standard.string(forKey: Key.appiumURL) ?? defaultAppiumURL) ?? URL(string: defaultAppiumURL)!
    }
    static var ollamaModel: String { UserDefaults.standard.string(forKey: Key.ollamaModel) ?? "" }
    static var defaultSimulator: String {
        UserDefaults.standard.string(forKey: Key.defaultSimulatorUDID) ?? defaultSimulatorUDID
    }
    static var disableSigning: Bool {
        UserDefaults.standard.object(forKey: Key.disableSigning) as? Bool ?? true
    }
}

/// Application data directories (build products, logs, evidence, exports).
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("AIQATestStudio", isDirectory: true))
    }()

    static var derivedDataRoot: URL { ensure(support.appendingPathComponent("DerivedData", isDirectory: true)) }
    static var logs: URL { ensure(support.appendingPathComponent("Logs", isDirectory: true)) }
    static var exports: URL { ensure(support.appendingPathComponent("Exports", isDirectory: true)) }
    static var defaultEvidence: URL { ensure(support.appendingPathComponent("Evidence", isDirectory: true)) }

    static var evidence: URL {
        if let custom = UserDefaults.standard.string(forKey: Prefs.Key.evidenceDirectory), !custom.isEmpty {
            return ensure(URL(fileURLWithPath: custom, isDirectory: true))
        }
        return defaultEvidence
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dedicated DerivedData directory per source project.
    static func derivedData(for projectPath: String) -> URL {
        let name = URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent
        return ensure(derivedDataRoot.appendingPathComponent("\(name)-\(shortHash(projectPath))", isDirectory: true))
    }

    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
