import Foundation

struct ExecutionConfig: Sendable {
    var udid: String
    var bundleID: String
    var deviceName: String
    var osVersion: String
    var appiumURL: URL
    var evidenceDirectory: URL
    /// Optional AI helper (page source, wanted element) → candidate locator. Candidates are re-validated live.
    var locatorModel: String?
    /// Visible text identifying the screen under test; when set the app is navigated there before each case.
    var navigationGoal: String = ""
    /// Static source-code analysis describing how that screen is reached.
    var navigationHints: String = ""
    /// Localised variants of the goal found in the source (what is really shown on screen).
    var navigationGoalTexts: [String] = []
    /// Texts of the screens that open the goal screen (from source analysis) — ranks what to tap.
    var navigationPathTexts: [String] = []
    var cachedNavigationPath: [String] = []
    /// Reads the source on demand — only called when no stored flow works and the screen has to be explored.
    var navigationHintsLoader: (@Sendable () async -> String)?
}

/// Cases the user asked to skip while a run is in progress (checked between steps, never mid-WebDriver call).
final class SkipController: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    func request(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func isSkipped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    func reset() { lock.lock(); ids.removeAll(); lock.unlock() }
}

/// Executes planned cases through Appium. Results come only from real WebDriver responses.
final class TestExecutionService {
    private let locatorSuggester: (@Sendable (String, String) async -> Locator?)?

    private let skip: SkipController
    /// Longest a single case may run before it is stopped and reported (a hung WebDriver call must not freeze the whole run).
    private let caseBudgetSeconds: Double = 150
    private var currentStep = ""

    init(locatorSuggester: (@Sendable (String, String) async -> Locator?)? = nil, skip: SkipController = SkipController()) {
        self.locatorSuggester = locatorSuggester
        self.skip = skip
    }

    // MARK: Run

    func execute(cases: [PlannedCase], config: ExecutionConfig, emit: @escaping @Sendable (ExecutionEvent) -> Void) async {
        emit(.runStarted(total: cases.count))
        let appium = AppiumService(baseURL: config.appiumURL)

        do {
            emit(.log("Creating Appium XCUITest session on \(config.deviceName) (\(config.udid))…", level: .info))
            try await appium.createSession(udid: config.udid, bundleID: config.bundleID,
                                           platformVersion: config.osVersion, deviceName: config.deviceName)
            emit(.log("Appium session established.", level: .success))
        } catch {
            let problem = error.userText
            emit(.log("Infrastructure problem: \(problem)", level: .error))
            for planned in cases { emit(.caseFinished(blocked(planned.id, problem))) }
            emit(.runFinished(infrastructureProblem: problem))
            return
        }

        var infrastructureProblem: String?
        var navigationPath: [String] = []
        var navigationProblem: String?
        let navigator = NavigationAgent(appium: appium, config: config, emit: emit)

        if !config.navigationGoal.isEmpty, cases.contains(where: { $0.effectiveReadiness == .ready }) {
            emit(.log("Tìm đường tới màn hình “\(config.navigationGoal)” (dựa trên phân tích source + UI thật)…", level: .info))
            do {
                let result = try await navigator.discover(goal: config.navigationGoal, cachedPath: config.cachedNavigationPath)
                if result.reached {
                    navigationPath = result.path
                    emit(.navigationPath(goal: config.navigationGoal, path: result.path, origin: result.origin))
                    emit(.log("Đã tới màn hình “\(config.navigationGoal)” qua: " + (result.path.isEmpty ? "(đã ở sẵn)" : result.path.joined(separator: " → ")), level: .success))
                } else {
                    navigationProblem = "Không điều hướng được tới màn hình “\(config.navigationGoal)”: \(result.reason ?? "không rõ lý do")"
                    emit(.log(navigationProblem ?? "", level: .error))
                }
            } catch is CancellationError {
                navigationProblem = "Cancelled by user."
            } catch let error as AppiumError where error.isInfrastructure {
                infrastructureProblem = error.userText
            } catch {
                navigationProblem = "Lỗi khi điều hướng: \(error.localizedDescription)"
            }
        }

        for (position, planned) in cases.enumerated() {
            if Task.isCancelled {
                for remaining in cases[position...] {
                    emit(.caseFinished(CaseOutcome(caseID: remaining.id, status: .cancelled, message: "Cancelled by user.",
                                                   startedAt: Date(), endedAt: Date(), assertionsExecuted: 0)))
                }
                break
            }
            if skip.isSkipped(planned.id) {
                emit(.caseFinished(CaseOutcome(caseID: planned.id, status: .skipped, message: "Bỏ qua theo yêu cầu.",
                                               startedAt: Date(), endedAt: Date(), assertionsExecuted: 0)))
                continue
            }
            if let problem = infrastructureProblem {
                emit(.caseFinished(blocked(planned.id, problem)))
                continue
            }
            do {
                emit(.caseFinished(try await guarded(planned, appium: appium, config: config, emit: emit) {
                    try await self.runCase(planned, appium: appium, config: config, navigator: navigator, path: navigationPath,
                                           navigationProblem: navigationProblem, emit: emit)
                }))
            } catch let failure as InfrastructureFailure {
                infrastructureProblem = failure.message
                emit(.log("Infrastructure problem — remaining cases are Blocked: \(failure.message)", level: .error))
                emit(.caseFinished(blocked(planned.id, failure.message)))
            } catch is CancellationError {
                emit(.caseFinished(CaseOutcome(caseID: planned.id, status: .cancelled, message: "Cancelled by user.",
                                               startedAt: Date(), endedAt: Date(), assertionsExecuted: 0)))
            } catch {
                let message = "Unexpected automation error: \(error.localizedDescription)"
                emit(.log(message, level: .error))
                emit(.caseFinished(blocked(planned.id, message)))
            }
        }

        // Detached so the session is closed even when this task was cancelled.
        await Task.detached { await appium.deleteSession() }.value
        emit(.runFinished(infrastructureProblem: infrastructureProblem))
    }

    /// Runs one case with a watchdog: the user's Skip button and the time budget both cancel the in-flight WebDriver call,
    /// so a case that hangs on one step ends (Skipped / Blocked + a screenshot) and the next case starts.
    private func guarded(_ planned: PlannedCase, appium: AppiumService, config: ExecutionConfig,
                         emit: @escaping @Sendable (ExecutionEvent) -> Void,
                         operation: @escaping () async throws -> CaseOutcome) async throws -> CaseOutcome {
        enum Race { case done(CaseOutcome), skipped, timedOut }
        let started = Date()
        let budget = caseBudgetSeconds
        currentStep = ""
        let first: Race
        do {
            first = try await withThrowingTaskGroup(of: Race.self) { group in
                group.addTask { .done(try await operation()) }
                group.addTask { [skip] in
                    let deadline = Date().addingTimeInterval(budget)
                    while true {
                        try await Task.sleep(nanoseconds: 400_000_000)
                        if skip.isSkipped(planned.id) { return .skipped }
                        if Date() > deadline { return .timedOut }
                    }
                }
                defer { group.cancelAll() }
                let result = try await group.next() ?? .skipped
                group.cancelAll()
                while true {   // let the cancelled case task finish before leaving the group
                    do { if try await group.next() == nil { break } } catch { continue }
                }
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        switch first {
        case .done(let outcome): return outcome
        case .skipped:
            return CaseOutcome(caseID: planned.id, status: .skipped, message: "Bỏ qua theo yêu cầu (đang ở bước: \(currentStep.isEmpty ? "—" : currentStep)).",
                               startedAt: started, endedAt: Date(), assertionsExecuted: 0)
        case .timedOut:
            let step = currentStep.isEmpty ? "—" : currentStep
            emit(.log("\(planned.id) quá \(Int(budget))s, bị treo ở bước \(step) — dừng case này và chạy case kế.", level: .error))
            if let shot = await captureEvidence(appium, caseID: planned.id, label: "timeout", config: config) {
                emit(.evidence(caseID: planned.id, url: shot, kind: "screenshot"))
            }
            return CaseOutcome(caseID: planned.id, status: .blocked,
                               message: "Quá thời gian \(Int(budget))s — bị treo ở bước: \(step). Case bị dừng để chạy tiếp các case sau.",
                               startedAt: started, endedAt: Date(), assertionsExecuted: 0)
        }
    }

    private func blocked(_ caseID: String, _ message: String) -> CaseOutcome {
        CaseOutcome(caseID: caseID, status: .blocked, message: message, startedAt: Date(), endedAt: Date(), assertionsExecuted: 0)
    }

    // MARK: Case

    private func runCase(_ planned: PlannedCase, appium: AppiumService, config: ExecutionConfig, navigator: NavigationAgent,
                         path: [String], navigationProblem: String?,
                         emit: @escaping @Sendable (ExecutionEvent) -> Void) async throws -> CaseOutcome {
        let started = Date()
        let data = planned.testDataValues

        switch planned.effectiveReadiness {
        case .needsTestData:
            let names = planned.missingTestData.map(\.name).joined(separator: ", ")
            emit(.log("\(planned.id) blocked: missing test data (\(names)).", level: .warning))
            return CaseOutcome(caseID: planned.id, status: .blocked, message: "Missing test data: \(names)",
                               startedAt: started, endedAt: Date(), assertionsExecuted: 0)
        case .needsReview:
            let why = planned.notes.joined(separator: " ")
            emit(.log("\(planned.id) needs review and was not executed. \(why)", level: .warning))
            return CaseOutcome(caseID: planned.id, status: .needsReview,
                               message: "Not executed — expected result or locators need review. \(why)",
                               startedAt: started, endedAt: Date(), assertionsExecuted: 0)
        case .ready:
            if let navigationProblem {
                return CaseOutcome(caseID: planned.id, status: .blocked, message: navigationProblem,
                                   startedAt: started, endedAt: Date(), assertionsExecuted: 0)
            }
        }

        emit(.caseStarted(caseID: planned.id, totalActions: planned.actions.count))
        var assertions = 0
        var final: (ExecutionStatus, String) = (.passed, "All steps completed.")

        for (index, action) in planned.actions.enumerated() {
            try Task.checkCancellation()
            if skip.isSkipped(planned.id) { final = (.skipped, "Bỏ qua theo yêu cầu."); break }
            emit(.actionStarted(caseID: planned.id, action: action, index: index))
            currentStep = "\(action.id) \(action.summary)"
            let stepStart = Date()
            var outcome: StepOutcome
            if index == 0, action.type == .relaunchApp, !path.isEmpty, (try? await navigator.softReset(path)) == true {
                emit(.log("   ↪ về màn hình đích bằng cách bấm đúp tab (không tắt/bật lại app).", level: .info))
                emit(.actionFinished(StepOutcome(caseID: planned.id, action: action, index: index, status: .passed, expected: action.expectedOutcome,
                                                 actual: "Returned to the screen under test by double-tapping its tab; app restart skipped.",
                                                 message: "Soft reset.", startedAt: stepStart, duration: Date().timeIntervalSince(stepStart),
                                                 locatorUsed: nil, aiSuggestedLocator: false, screenshot: nil)))
                continue
            }
            do {
                outcome = try await perform(action, index: index, appium: appium, config: config, data: data, emit: emit)
            } catch let error as AppiumError where error.isInfrastructure {
                throw InfrastructureFailure(message: error.userText)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppiumError {
                outcome = StepOutcome(caseID: planned.id, action: action, index: index, status: .needsReview,
                                      expected: action.expectedOutcome, actual: error.userText,
                                      message: "Automation could not complete this step: \(error.userText)",
                                      startedAt: stepStart, duration: Date().timeIntervalSince(stepStart),
                                      locatorUsed: nil, aiSuggestedLocator: false, screenshot: nil)
            }
            if action.type.isAssertion && (outcome.status == .passed || outcome.status == .failed) { assertions += 1 }
            emit(.actionFinished(outcome))
            if action.type.isAssertion, outcome.status == .passed,
               let shot = await captureEvidence(appium, caseID: planned.id, label: "\(action.id)-pass", config: config) {
                emit(.evidence(caseID: planned.id, url: shot, kind: "screenshot"))
            }

            // After a fresh launch, walk the discovered route back to the screen under test.
            if outcome.status == .passed, !path.isEmpty, action.type == .relaunchApp || action.type == .launchApp {
                emit(.log("   ↪ quay lại màn hình đích: \(path.joined(separator: " → "))", level: .info))
                if try await !navigator.replay(path) {
                    final = (.blocked, "Không quay lại được màn hình đích sau khi mở lại app (đường đi \(path.joined(separator: " → ")) không còn đúng).")
                    break
                }
                if try await !navigator.isAtGoal() {
                    final = (.blocked, "Đã bấm đúng đường đi nhưng không thấy màn hình “\(config.navigationGoal)” — không chạy tiếp để tránh kiểm tra nhầm màn hình.")
                    break
                }
            }

            if outcome.status != .passed {
                final = (outcome.status, outcome.message)
                if let shot = await captureEvidence(appium, caseID: planned.id, label: "\(action.id)-\(outcome.status.rawValue)", config: config) {
                    emit(.evidence(caseID: planned.id, url: shot, kind: "screenshot"))
                }
                if outcome.status == .needsReview, let source = try? await appium.pageSource() {
                    let url = config.evidenceDirectory.appendingPathComponent("\(planned.id)-\(action.id)-pagesource.xml")
                    try? source.write(to: url, atomically: true, encoding: .utf8)
                    emit(.evidence(caseID: planned.id, url: url, kind: "pageSource"))
                }
                break
            }
        }

        if final.0 == .passed {
            if assertions == 0 {
                final = (.needsReview, "No assertion was executed, so the result cannot be verified.")
            } else if let shot = await captureEvidence(appium, caseID: planned.id, label: "final", config: config) {
                emit(.evidence(caseID: planned.id, url: shot, kind: "screenshot"))
            }
        }
        return CaseOutcome(caseID: planned.id, status: final.0, message: final.1, startedAt: started,
                           endedAt: Date(), assertionsExecuted: assertions)
    }

    private func captureEvidence(_ appium: AppiumService, caseID: String, label: String, config: ExecutionConfig) async -> URL? {
        var capture: Data?
        for attempt in 0..<3 where capture == nil {
            capture = try? await appium.screenshot()
            if capture == nil { try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1))) }
        }
        guard let png = capture else { return nil }
        let url = config.evidenceDirectory.appendingPathComponent("\(caseID)-\(label).png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    // MARK: Action

    private func perform(_ action: TestAction, index: Int, appium: AppiumService, config: ExecutionConfig, data: [String: String],
                         emit: @escaping @Sendable (ExecutionEvent) -> Void) async throws -> StepOutcome {
        let started = Date()
        var used: String?
        var aiSuggested = false

        func result(_ status: ExecutionStatus, actual: String, message: String? = nil, screenshot: URL? = nil) -> StepOutcome {
            StepOutcome(caseID: action.sourceTestCaseID, action: action, index: index, status: status,
                        expected: action.expectedOutcome.isEmpty ? action.summary : action.expectedOutcome,
                        actual: actual, message: message ?? actual, startedAt: started,
                        duration: Date().timeIntervalSince(started), locatorUsed: used,
                        aiSuggestedLocator: aiSuggested, screenshot: screenshot)
        }

        func args(_ key: String) -> (value: String, missing: [String]) {
            let (text, missing) = TestPlanGenerator.substitute(action.arguments[key] ?? "", data: data)
            return (text, missing)
        }

        func locate(timeout: Double) async throws -> String? {
            let found = try await locateElement(action, timeout: timeout, appium: appium, config: config, emit: emit)
            used = found?.locator.summary
            aiSuggested = found?.aiSuggested ?? false
            return found?.element
        }

        func notFound() -> StepOutcome {
            result(.needsReview, actual: "No element matched \(action.allLocators.map(\.summary).joined(separator: " | ")) within \(Int(action.timeoutSeconds))s.",
                   message: "Locator could not be validated against the live UI — review the locator (see saved page source).")
        }

        switch action.type {
        case .launchApp:
            try await appium.mobile("launchApp", ["bundleId": config.bundleID])
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return result(.passed, actual: "App launched.")

        case .relaunchApp:
            try? await appium.mobile("terminateApp", ["bundleId": config.bundleID])
            try await appium.mobile("launchApp", ["bundleId": config.bundleID])
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return result(.passed, actual: "App relaunched.")

        case .takeScreenshot:
            let name = action.arguments["name"].map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } } ?? ""
            guard let url = await captureEvidence(appium, caseID: action.sourceTestCaseID, label: name.isEmpty ? action.id : name, config: config) else {
                return result(.needsReview, actual: "Screenshot could not be captured.")
            }
            emit(.evidence(caseID: action.sourceTestCaseID, url: url, kind: "screenshot"))
            return result(.passed, actual: "Screenshot saved.", screenshot: url)

        case .swipe, .scroll:
            let direction = action.arguments["direction"] ?? "up"
            guard ["up", "down", "left", "right"].contains(direction) else {
                return result(.needsReview, actual: "Invalid direction “\(direction)”.")
            }
            var parameters: [String: Any] = ["direction": direction]
            if action.target != nil {
                guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
                parameters["elementId"] = element
            }
            try await appium.mobile(action.type == .swipe ? "swipe" : "scroll", parameters)
            return result(.passed, actual: "\(action.type.rawValue) \(direction) performed.")

        case .goBack:
            let chain = "**/XCUIElementTypeNavigationBar/XCUIElementTypeButton[1]"
            guard let button = try await appium.find(using: "-ios class chain", value: chain) else {
                return result(.needsReview, actual: "No navigation bar back button found.")
            }
            try await appium.click(button)
            return result(.passed, actual: "Tapped navigation back button.")

        case .tap:
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            try await appium.click(element)
            return result(.passed, actual: "Tapped \(used ?? "element").")

        case .typeText:
            let (text, missing) = args("text")
            if !missing.isEmpty { return result(.blocked, actual: "Missing test data: \(missing.joined(separator: ", "))") }
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            try await appium.type(text, into: element)
            return result(.passed, actual: "Typed text into \(used ?? "element").")

        case .clearText:
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            try await appium.clear(element)
            return result(.passed, actual: "Cleared \(used ?? "element").")

        case .waitForElement:
            guard try await locate(timeout: action.timeoutSeconds) != nil else { return notFound() }
            return result(.passed, actual: "Element appeared (\(used ?? "")).")

        case .assertVisible:
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            let visible = try await appium.isDisplayed(element)
            return visible ? result(.passed, actual: "Element is visible.")
                           : result(.failed, actual: "Element exists but is not visible.", message: "Expected element to be visible, but it is hidden.")

        case .assertNotVisible:
            let deadline = Date().addingTimeInterval(action.timeoutSeconds)
            var lastState = "not present"
            repeat {
                try Task.checkCancellation()
                let found = try await locateElement(action, timeout: 0, appium: appium, config: config, emit: emit, allowAI: false)
                if let found {
                    used = found.locator.summary
                    if try await appium.isDisplayed(found.element) { lastState = "still visible" } else { return result(.passed, actual: "Element is hidden.") }
                } else {
                    return result(.passed, actual: "Element is not present.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            } while Date() < deadline
            return result(.failed, actual: "Element is \(lastState) after \(Int(action.timeoutSeconds))s.",
                          message: "Expected element not to be visible.")

        case .assertText:
            let (expected, missing) = args(action.arguments["expectedText"] != nil ? "expectedText" : "text")
            if !missing.isEmpty { return result(.blocked, actual: "Missing test data: \(missing.joined(separator: ", "))") }
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            var actual = try await appium.text(of: element)
            if actual.isEmpty { actual = try await appium.attribute("value", of: element) ?? "" }
            let contains = action.arguments["match"] == "contains"
            let matches = contains ? actual.contains(expected) : actual == expected
            return matches ? result(.passed, actual: "Text “\(actual)” matches.")
                           : result(.failed, actual: "Actual text: “\(actual)”",
                                    message: "Expected text \(contains ? "containing" : "equal to") “\(expected)” but found “\(actual)”.")

        case .assertEnabled, .assertDisabled:
            guard let element = try await locate(timeout: action.timeoutSeconds) else { return notFound() }
            let enabled = try await appium.isEnabled(element)
            let wantEnabled = action.type == .assertEnabled
            return enabled == wantEnabled ? result(.passed, actual: enabled ? "Element is enabled." : "Element is disabled.")
                                          : result(.failed, actual: enabled ? "Element is enabled." : "Element is disabled.",
                                                   message: "Expected element to be \(wantEnabled ? "enabled" : "disabled").")
        }
    }

    // MARK: Locator resolution (identifier → label/name → type+attribute → AI suggestion, always validated live)

    private func locateElement(_ action: TestAction, timeout: Double, appium: AppiumService, config: ExecutionConfig,
                               emit: @escaping @Sendable (ExecutionEvent) -> Void,
                               allowAI: Bool = true) async throws -> (element: String, locator: Locator, aiSuggested: Bool)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try Task.checkCancellation()
            for locator in action.allLocators {
                if let element = try await appium.find(locator) { return (element, locator, false) }
            }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline

        guard allowAI, let suggester = locatorSuggester, config.locatorModel != nil, let wanted = action.target else { return nil }
        emit(.log("Locator \(wanted.summary) not found — asking local AI for a candidate from the UI hierarchy…", level: .warning))
        guard let source = try? await appium.pageSource(),
              let suggestion = await suggester(source, "\(action.type.rawValue): \(action.expectedOutcome) (original locator \(wanted.summary))"),
              let element = try await appium.find(suggestion) else { return nil }
        emit(.log("AI-suggested locator \(suggestion.summary) validated against the live UI.", level: .warning))
        return (element, suggestion, true)
    }
}
