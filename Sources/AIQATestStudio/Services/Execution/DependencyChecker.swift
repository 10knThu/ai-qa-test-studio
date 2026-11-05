import Foundation

struct DependencyStatus: Identifiable, Sendable {
    let name: String
    let ok: Bool
    let detail: String
    let installHint: String
    var id: String { name }
}

/// Reports what is installed. Never installs anything by itself.
struct DependencyChecker {

    func checkAll() async -> [DependencyStatus] {
        async let xcode = checkXcode()
        async let runtime = checkRuntime()
        async let node = checkTool("Node.js", "node", ["--version"], hint: "brew install node")
        async let appium = checkTool("Appium", "appium", ["--version"], hint: "npm install -g appium")
        async let driver = checkDriver()
        async let appiumServer = checkAppiumServer()
        async let ollama = checkOllama()
        return await [xcode, runtime, node, appium, driver, appiumServer, ollama]
    }

    func checkXcode() async -> DependencyStatus {
        let hint = "Install Xcode from the App Store, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`."
        guard let version = try? await ProcessRunner.run("/usr/bin/xcodebuild", ["-version"]), version.succeeded else {
            return .init(name: "Xcode", ok: false, detail: "xcodebuild is not available", installHint: hint)
        }
        let path = (try? await ProcessRunner.run("/usr/bin/xcode-select", ["-p"]))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .init(name: "Xcode", ok: true, detail: version.output.replacingOccurrences(of: "\n", with: " ") + " · " + path, installHint: hint)
    }

    func checkRuntime() async -> DependencyStatus {
        let hint = "Xcode ▸ Settings ▸ Components ▸ install an iOS Simulator runtime."
        guard let devices = try? await SimulatorService().listDevices() else {
            return .init(name: "iOS Simulator runtime", ok: false, detail: "No available iOS Simulator devices", installHint: hint)
        }
        let versions = Set(devices.map(\.osVersion)).sorted().joined(separator: ", ")
        return .init(name: "iOS Simulator runtime", ok: true, detail: "iOS \(versions) · \(devices.count) devices", installHint: hint)
    }

    private func checkTool(_ title: String, _ tool: String, _ args: [String], hint: String) async -> DependencyStatus {
        guard let result = try? await ProcessRunner.runTool(tool, args), result.succeeded else {
            return .init(name: title, ok: false, detail: "Not found on PATH", installHint: hint)
        }
        return .init(name: title, ok: true, detail: result.output.tailLines(1), installHint: hint)
    }

    func checkDriver() async -> DependencyStatus {
        let hint = "appium driver install xcuitest"
        guard let result = try? await ProcessRunner.runTool("appium", ["driver", "list", "--installed"]), result.succeeded else {
            return .init(name: "XCUITest driver", ok: false, detail: "Appium not available", installHint: hint)
        }
        let installed = result.output.localizedCaseInsensitiveContains("xcuitest")
        return .init(name: "XCUITest driver", ok: installed, detail: installed ? "Installed" : "Not installed", installHint: hint)
    }

    func checkAppiumServer() async -> DependencyStatus {
        let hint = "Start it in a terminal: appium --port 4723"
        do {
            let message = try await AppiumService().serverStatus()
            return .init(name: "Appium server", ok: true, detail: "\(Prefs.appiumURL.absoluteString) — \(message)", installHint: hint)
        } catch {
            return .init(name: "Appium server", ok: false, detail: "Not reachable at \(Prefs.appiumURL.absoluteString)", installHint: hint)
        }
    }

    func checkOllama() async -> DependencyStatus {
        let hint = OllamaService.setupInstructions
        do {
            let service = OllamaService()
            let version = try await service.version()
            let models = try await service.models()
            return .init(name: "Ollama", ok: !models.isEmpty,
                         detail: "v\(version) · \(models.count) model(s)" + (models.isEmpty ? " — pull a model first" : ""), installHint: hint)
        } catch {
            return .init(name: "Ollama", ok: false, detail: "Not running at \(Prefs.ollamaURL.absoluteString)", installHint: hint)
        }
    }
}
