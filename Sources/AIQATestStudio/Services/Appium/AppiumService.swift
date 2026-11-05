import Foundation

enum AppiumError: LocalizedError {
    case serverUnavailable(String)
    case sessionCreationFailed(String)
    case sessionLost(String)
    case webDriver(error: String, message: String)

    /// Infrastructure problems must never be reported as a failed test.
    var isInfrastructure: Bool {
        switch self {
        case .serverUnavailable, .sessionCreationFailed, .sessionLost: return true
        case .webDriver(let error, let message):
            let text = (error + message).lowercased()
            return text.contains("webdriveragent") || text.contains("econnrefused") || text.contains("socket hang up")
                || error == "invalid session id" || error == "session not created"
        }
    }

    var isNoSuchElement: Bool {
        if case .webDriver(let error, _) = self { return error == "no such element" }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .serverUnavailable(let text): return "Appium server is not reachable: \(text)"
        case .sessionCreationFailed(let text): return "Appium could not create a session: \(text)"
        case .sessionLost(let text): return "The Appium session was lost: \(text)"
        case .webDriver(let error, let message): return "\(error): \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .serverUnavailable:
            return "Start Appium in a terminal: `appium --port 4723` (install: `npm i -g appium && appium driver install xcuitest`)."
        case .sessionCreationFailed(let text):
            if text.localizedCaseInsensitiveContains("webdriveragent") || text.localizedCaseInsensitiveContains("xcodebuild") {
                return "WebDriverAgent failed to start. Open Appium's WebDriverAgent project once in Xcode, set a team/signing if prompted, and ensure the Simulator is booted. See the Appium log for details."
            }
            return "Check `appium driver list --installed` shows xcuitest, and that Xcode + the Simulator runtime are healthy."
        case .sessionLost:
            return "Restart the run. If it recurs, restart Appium and the Simulator."
        case .webDriver: return nil
        }
    }
}

/// Minimal W3C WebDriver / Appium client over URLSession.
final class AppiumService {
    private let baseURL: URL
    private let http: URLSession
    private(set) var sessionID: String?
    private let elementKey = "element-6066-11e4-a52e-4f735466cecf"

    init(baseURL: URL = Prefs.appiumURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        self.http = URLSession(configuration: config)
    }

    // MARK: Transport

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 120) async throws -> Any? {
        var url = baseURL
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await http.data(for: request) } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if sessionID == nil { throw AppiumError.serverUnavailable("\(baseURL.absoluteString) — \(error.localizedDescription)") }
            throw AppiumError.sessionLost(error.localizedDescription)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = json?["value"]
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            let dict = value as? [String: Any]
            let error = dict?["error"] as? String ?? "http \(status)"
            let message = dict?["message"] as? String ?? String(decoding: data.prefix(400), as: UTF8.self)
            if path == "session" { throw AppiumError.sessionCreationFailed(message) }
            if error == "invalid session id" { throw AppiumError.sessionLost(message) }
            throw AppiumError.webDriver(error: error, message: message)
        }
        return value
    }

    private func sessionPath(_ suffix: String) throws -> String {
        guard let sessionID else { throw AppiumError.sessionLost("No active session.") }
        return "session/\(sessionID)/\(suffix)"
    }

    // MARK: Session

    func serverStatus() async throws -> String {
        let value = try await request("GET", "status", timeout: 5) as? [String: Any]
        return (value?["message"] as? String) ?? "ready"
    }

    func createSession(udid: String, bundleID: String, platformVersion: String?, deviceName: String?) async throws {
        _ = try await serverStatus()
        var caps: [String: Any] = [
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": udid,
            "appium:bundleId": bundleID,
            "appium:noReset": true,
            "appium:autoAcceptAlerts": true,   // notification / tracking permission prompts must not block navigation
            "appium:newCommandTimeout": 300,
            "appium:wdaLaunchTimeout": 240_000,
            "appium:wdaConnectionTimeout": 240_000,
        ]
        if let platformVersion { caps["appium:platformVersion"] = platformVersion }
        if let deviceName { caps["appium:deviceName"] = deviceName }
        let value = try await request("POST", "session", body: ["capabilities": ["alwaysMatch": caps]], timeout: 600) as? [String: Any]
        guard let id = value?["sessionId"] as? String else {
            throw AppiumError.sessionCreationFailed("Appium did not return a session id.")
        }
        sessionID = id
        try await request("POST", try sessionPath("timeouts"), body: ["implicit": 0])
    }

    func deleteSession() async {
        guard let id = sessionID else { return }
        _ = try? await request("DELETE", "session/\(id)", timeout: 15)
        sessionID = nil
    }

    // MARK: Elements

    private static func predicateEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func query(for locator: Locator) -> (using: String, value: String)? {
        let value = Self.predicateEscape(locator.value)
        switch locator.strategy {
        case .accessibilityId: return ("accessibility id", locator.value)
        case .label: return ("-ios predicate string", "label == \"\(value)\"")
        case .name: return ("-ios predicate string", "name == \"\(value)\"")
        case .labelMatches: return ("-ios predicate string", "label MATCHES \"\(value)\"")
        case .typeAndAttribute:
            guard let type = locator.elementType, type.range(of: #"^XCUIElementType[A-Za-z]+$"#, options: .regularExpression) != nil else { return nil }
            return ("-ios predicate string", "type == \"\(type)\" AND (label == \"\(value)\" OR name == \"\(value)\" OR value == \"\(value)\")")
        }
    }

    /// Returns the element id or nil when the locator matches nothing.
    func find(_ locator: Locator) async throws -> String? {
        guard let query = query(for: locator) else { return nil }
        return try await find(using: query.using, value: query.value)
    }

    func find(using: String, value: String) async throws -> String? {
        do {
            let result = try await request("POST", try sessionPath("element"), body: ["using": using, "value": value]) as? [String: Any]
            return (result?[elementKey] as? String) ?? (result?["ELEMENT"] as? String)
        } catch let error as AppiumError where error.isNoSuchElement {
            return nil
        }
    }

    func click(_ element: String) async throws { try await request("POST", try sessionPath("element/\(element)/click"), body: [:]) }
    func clear(_ element: String) async throws { try await request("POST", try sessionPath("element/\(element)/clear"), body: [:]) }

    func type(_ text: String, into element: String) async throws {
        try await request("POST", try sessionPath("element/\(element)/value"), body: ["text": text, "value": text.map { String($0) }])
    }

    func isDisplayed(_ element: String) async throws -> Bool {
        try await request("GET", try sessionPath("element/\(element)/displayed")) as? Bool ?? false
    }

    func isEnabled(_ element: String) async throws -> Bool {
        try await request("GET", try sessionPath("element/\(element)/enabled")) as? Bool ?? false
    }

    func text(of element: String) async throws -> String {
        try await request("GET", try sessionPath("element/\(element)/text")) as? String ?? ""
    }

    func attribute(_ name: String, of element: String) async throws -> String? {
        try await request("GET", try sessionPath("element/\(element)/attribute/\(name)")) as? String
    }

    // MARK: Device / app

    func screenshot() async throws -> Data {
        guard let base64 = try await request("GET", try sessionPath("screenshot")) as? String,
              let data = Data(base64Encoded: base64) else {
            throw AppiumError.webDriver(error: "screenshot", message: "Appium returned no screenshot data.")
        }
        return data
    }

    func pageSource() async throws -> String {
        try await request("GET", try sessionPath("source")) as? String ?? ""
    }

    /// XCUIApplication.State raw value: 4 = running in foreground.
    func appState(bundleID: String) async throws -> Int {
        let value = try await request("POST", try sessionPath("execute/sync"), body: ["script": "mobile: queryAppState", "args": [["bundleId": bundleID]]])
        return (value as? NSNumber)?.intValue ?? -1
    }

    func mobile(_ command: String, _ arguments: [String: Any]) async throws {
        try await request("POST", try sessionPath("execute/sync"), body: ["script": "mobile: \(command)", "args": [arguments]])
    }
}
