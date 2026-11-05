import Foundation
import Observation
import AppKit
import SwiftData

/// Source folder → scheme → build → boot → install → launch.
@MainActor
@Observable
final class SourceProjectViewModel {
    let simulator: SimulatorViewModel
    private let context: ModelContext
    private let projectService = SourceProjectService()
    private let buildService = XcodeBuildService()

    // Selection
    var sourceURL: URL?
    var containers: [XcodeContainer] = []
    var selectedContainerID: String = ""
    var schemes: [String] = []
    var selectedScheme = ""
    var configurations = ["Debug", "Release"]
    var selectedConfiguration = "Debug"
    var targets: [AppTarget] = []
    var bundleIdentifier = ""
    var isReadingBundle = false
    @ObservationIgnored private var bundleRefreshToken = 0
    var preflightIssues: [String] = []
    var scanError: String?
    var isScanning = false
    var knownIdentifiers: Set<String> = []

    // Pipeline
    var buildStage: StageState = .idle
    var installStage: StageState = .idle
    var launchStage: StageState = .idle
    var currentOperation = ""
    var buildStepCount = 0
    var builtApp: BuiltApp?
    /// Issue the current `builtApp` belongs to.
    var builtForIssue: String?
    var lastBuildLogPath: String?
    let log = LogStore()
    private var pipelineTask: Task<Bool, Never>?

    var bootStage: StageState { simulator.bootStage }
    var isBusy: Bool { pipelineTask != nil }
    var selectedContainer: XcodeContainer? { containers.first { $0.id == selectedContainerID } }
    var canBuild: Bool { selectedContainer != nil && !selectedScheme.isEmpty && simulator.selected != nil && !isBusy }

    init(simulator: SimulatorViewModel, context: ModelContext) {
        self.simulator = simulator
        self.context = context
        log.onLine = { [weak self] line in self?.noteBuildLine(line) }
    }

    // MARK: Folder selection

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Source Folder"
        panel.message = "Choose the folder of an existing native iOS (Xcode) project. Its source code is never modified."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func restoreLastFolder() async {
        guard sourceURL == nil, let data = UserDefaults.standard.data(forKey: Prefs.Key.lastSourceBookmark),
              let url = projectService.resolveBookmark(data), FileManager.default.fileExists(atPath: url.path) else { return }
        await open(url)
    }

    func open(_ url: URL) async {
        sourceURL = url
        UserDefaults.standard.set(url.path, forKey: Prefs.Key.lastSourcePath)
        if let bookmark = projectService.makeBookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: Prefs.Key.lastSourceBookmark)
        }
        builtApp = nil
        builtForIssue = nil
        buildStage = .idle; installStage = .idle; launchStage = .idle
        simulator.bootStage = .idle
        await scan()
    }

    func scan() async {
        guard let root = sourceURL else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        let service = projectService
        let found = await Task.detached { service.detectContainers(in: root) }.value
        containers = found
        guard let first = found.first else {
            selectedContainerID = ""; schemes = []; selectedScheme = ""
            scanError = "No .xcworkspace or .xcodeproj was found in \(root.lastPathComponent) (searched 4 levels deep). "
                + "Native Xcode projects are supported. Flutter / React Native projects need their iOS folder generated first (e.g. `flutter build ios --config-only`, `pod install`)."
            return
        }
        selectedContainerID = first.id
        await loadSchemes()
        knownIdentifiers = await projectService.scanAccessibilityIdentifiers(in: root)
    }

    func loadSchemes() async {
        guard let container = selectedContainer else { return }
        scanError = nil
        preflightIssues = projectService.preflightIssues(for: container)
        do {
            let info = try await projectService.loadSchemes(for: container)
            schemes = info.schemes
            configurations = info.configurations
            selectedScheme = info.schemes.first { $0 == container.name } ?? info.schemes[0]
            selectedConfiguration = info.configurations.contains("Debug") ? "Debug" : info.configurations[0]
            await refreshBundleIdentifier()
            saveRecord()
        } catch {
            schemes = []; selectedScheme = ""
            scanError = error.userText
        }
    }

    /// Reads the bundle id for the CURRENT scheme + configuration. Slow (xcodebuild), so results of superseded
    /// requests are discarded — otherwise an older answer could overwrite the one for the latest selection.
    func refreshBundleIdentifier() async {
        guard let container = selectedContainer, !selectedScheme.isEmpty else { return }
        bundleRefreshToken += 1
        let token = bundleRefreshToken
        let scheme = selectedScheme, configuration = selectedConfiguration
        isReadingBundle = true
        bundleIdentifier = ""
        defer { if token == bundleRefreshToken { isReadingBundle = false } }
        do {
            let found = try await buildService.appTargets(container: container, scheme: scheme, configuration: configuration)
            guard token == bundleRefreshToken else { return }
            targets = found
            bundleIdentifier = (found.first { $0.targetName == scheme } ?? found.first)?.bundleID ?? ""
        } catch {
            guard token == bundleRefreshToken else { return }
            targets = []; bundleIdentifier = ""
            if !preflightIssues.contains(error.userText) { preflightIssues.append(error.userText) }
        }
    }

    private func saveRecord() {
        guard let root = sourceURL, let container = selectedContainer else { return }
        let path = root.path
        let existing = try? context.fetch(FetchDescriptor<SourceProjectRecord>(predicate: #Predicate { $0.path == path })).first
        let record = existing ?? SourceProjectRecord(path: path)
        if existing == nil { context.insert(record) }
        record.bookmark = projectService.makeBookmark(for: root)
        record.containerPath = container.url.path
        record.containerKind = container.kind.rawValue
        record.scheme = selectedScheme
        record.configuration = selectedConfiguration
        record.bundleIdentifier = bundleIdentifier
        record.lastUsed = Date()
        try? context.save()
    }

    // MARK: Pipeline

    private func noteBuildLine(_ line: String) {
        guard buildStage.isRunning, let operation = XcodeBuildService.operation(from: line) else { return }
        currentOperation = operation
        buildStepCount += 1
        buildStage = .running(operation)
    }

    @discardableResult
    func build(issueURL: String? = nil) async -> Bool {
        guard let container = selectedContainer, !selectedScheme.isEmpty else {
            buildStage = .failed("Select a source folder and scheme first.")
            return false
        }
        guard let device = simulator.selected else {
            buildStage = .failed("Select a Simulator first.")
            return false
        }
        let derivedData = AppPaths.derivedData(for: container.url.path)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let logURL = AppPaths.logs.appendingPathComponent("build-\(container.name)-\(stamp).log")
        log.clear()
        log.startFile(logURL)
        lastBuildLogPath = logURL.path
        buildStepCount = 0
        currentOperation = "Starting xcodebuild…"
        buildStage = .running(currentOperation)
        builtApp = nil
        installStage = .idle
        launchStage = .idle

        let record = BuildRecord(scheme: selectedScheme, configuration: selectedConfiguration, projectPath: container.url.path,
                                 simulatorUDID: device.udid, simulatorName: device.name, osVersion: device.osVersion)
        record.logPath = logURL.path
        record.issueURL = issueURL
        context.insert(record)

        let service = buildService
        let scheme = selectedScheme, configuration = selectedConfiguration
        let signing = Prefs.disableSigning
        let started = Date()
        defer { log.closeFile(); record.finishedAt = Date(); try? context.save() }
        do {
            let app = try await log.capture { emit in
                try await service.build(container: container, scheme: scheme, configuration: configuration,
                                        simulatorUDID: device.udid, disableSigning: signing, derivedData: derivedData, onLine: emit)
            }
            builtApp = app
            builtForIssue = issueURL
            bundleIdentifier = app.bundleID
            record.success = true
            record.appPath = app.appURL.path
            record.bundleIdentifier = app.bundleID
            let seconds = Int(Date().timeIntervalSince(started))
            buildStage = .succeeded("Built \(app.productName) in \(seconds)s")
            log.append("✔ Build succeeded: \(app.appURL.path)", level: .success)
            saveRecord()
            return true
        } catch is CancellationError {
            record.errorSummary = "Cancelled"
            buildStage = .cancelled
            log.append("Build cancelled.", level: .warning)
            return false
        } catch {
            record.errorSummary = error.userText
            buildStage = .failed(error.userText)
            log.append(error.userText, level: .error)
            return false
        }
    }

    @discardableResult
    func boot() async -> Bool { await simulator.boot() }

    @discardableResult
    func install() async -> Bool {
        guard let device = simulator.selected else { installStage = .failed("Select a Simulator first."); return false }
        guard let app = builtApp else { installStage = .failed("Nothing to install — build the project first."); return false }
        guard device.isBooted else { installStage = .failed("Boot \(device.name) first."); return false }
        installStage = .running("Installing \(app.productName)…")
        log.append("▶ simctl install \(device.udid) \(app.appURL.path)")
        let service = simulator.service
        do {
            try await log.capture { emit in try await service.install(udid: device.udid, appURL: app.appURL, onLine: emit) }
            installStage = .succeeded("Installed \(app.bundleID)")
            log.append("✔ Installed \(app.bundleID)", level: .success)
            return true
        } catch is CancellationError {
            installStage = .cancelled; return false
        } catch {
            installStage = .failed(error.userText); log.append(error.userText, level: .error); return false
        }
    }

    @discardableResult
    func launch() async -> Bool {
        guard let device = simulator.selected else { launchStage = .failed("Select a Simulator first."); return false }
        guard let app = builtApp else { launchStage = .failed("Nothing to launch — build and install first."); return false }
        guard installStage.isSucceeded else { launchStage = .failed("Install the app first."); return false }
        launchStage = .running("Launching \(app.bundleID)…")
        log.append("▶ simctl launch \(device.udid) \(app.bundleID)")
        let service = simulator.service
        do {
            let pid = try await service.launch(udid: device.udid, bundleID: app.bundleID)
            launchStage = .succeeded("Running" + (pid.map { " (pid \($0))" } ?? ""))
            log.append("✔ Launched \(app.bundleID)", level: .success)
            return true
        } catch is CancellationError {
            launchStage = .cancelled; return false
        } catch {
            launchStage = .failed(error.userText); log.append(error.userText, level: .error); return false
        }
    }

    /// A successful build made for this issue / project / scheme / simulator whose .app is still on disk.
    func reusableBuild(for issueURL: String) -> (app: BuiltApp, date: Date)? {
        guard let container = selectedContainer, let device = simulator.selected else { return nil }
        let records = (try? context.fetch(FetchDescriptor<BuildRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
        guard let match = records.first(where: {
            $0.success && $0.issueURL == issueURL && $0.projectPath == container.url.path && $0.scheme == selectedScheme
                && $0.configuration == selectedConfiguration && $0.simulatorUDID == device.udid
                && $0.appPath.map { FileManager.default.fileExists(atPath: $0 + "/_CodeSignature") } == true && $0.bundleIdentifier != nil
        }), let path = match.appPath, let bundleID = match.bundleIdentifier else { return nil }
        let url = URL(fileURLWithPath: path)
        return (BuiltApp(appURL: url, bundleID: bundleID, productName: url.lastPathComponent, targetName: selectedScheme), match.startedAt)
    }

    /// Whole pipeline; stops at the first failing stage. With an `issueURL` the app is built ONCE per issue and
    /// reused afterwards; without one (manual use) it always builds.
    @discardableResult
    func buildAndRun(issueURL: String? = nil) async -> Bool {
        // Boot the Simulator while the (slow) build runs: its window opens immediately and boot time is hidden.
        async let bootInParallel = boot()

        if let issueURL, let reusable = reusableBuild(for: issueURL) {
            builtApp = reusable.app
            builtForIssue = issueURL
            bundleIdentifier = reusable.app.bundleID
            buildStage = .succeeded("Reusing this issue's build from \(reusable.date.formatted()) — no rebuild")
            installStage = .idle
            launchStage = .idle
            log.append("↺ Reusing existing build for this issue: \(reusable.app.appURL.path)", level: .success)
        } else if await !build(issueURL: issueURL) {
            _ = await bootInParallel
            return false
        }
        guard await bootInParallel else { return false }
        guard await install() else { return false }
        return await launch()
    }

    /// Static analysis of the source: how is the screen titled `goal` reached?
    private var analysisCache: [String: SourceNavigationAnalyzer.Analysis] = [:]

    func navigationAnalysis(goal: String) async -> SourceNavigationAnalyzer.Analysis {
        guard let root = sourceURL, !goal.isEmpty else { return .init(hints: "", goalTexts: [goal]) }
        let cacheKey = root.path + "\u{0}" + goal
        if let cached = analysisCache[cacheKey] { return cached }
        let analysis = await Task.detached(priority: .userInitiated) { SourceNavigationAnalyzer.analyze(root: root, goal: goal) }.value
        analysisCache[cacheKey] = analysis
        return analysis
    }

    // MARK: Cancellable entry points for buttons

    func start(_ operation: @escaping @MainActor (SourceProjectViewModel) async -> Void) {
        guard pipelineTask == nil else { return }
        pipelineTask = Task { [weak self] () -> Bool in
            guard let self else { return false }
            await operation(self)
            self.pipelineTask = nil
            return true
        }
    }

    /// Awaitable full pipeline that the Cancel button can stop (used by Generate & Run / Test Runner).
    func runPipeline(issueURL: String? = nil) async -> Bool {
        guard pipelineTask == nil else { return false }
        let task = Task { [weak self] () -> Bool in
            let ok = await self?.buildAndRun(issueURL: issueURL) ?? false
            self?.pipelineTask = nil
            return ok
        }
        pipelineTask = task
        return await task.value
    }

    func cancel() {
        pipelineTask?.cancel()
        log.append("Cancelling…", level: .warning)
    }
}
