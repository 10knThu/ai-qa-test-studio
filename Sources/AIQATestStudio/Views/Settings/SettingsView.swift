import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.Key.ollamaURL) private var ollamaURL = Prefs.defaultOllamaURL
    @AppStorage(Prefs.Key.ollamaModel) private var ollamaModel = ""
    @AppStorage(Prefs.Key.appiumURL) private var appiumURL = Prefs.defaultAppiumURL
    @AppStorage(Prefs.Key.defaultSimulatorUDID) private var defaultSimulator = Prefs.defaultSimulatorUDID
    @AppStorage(Prefs.Key.evidenceDirectory) private var evidenceDirectory = ""

    var body: some View {
        let settings = app.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "GitHub") {
                    HStack {
                        Image(systemName: app.github.isConnected ? "checkmark.seal.fill" : "key")
                            .foregroundStyle(app.github.isConnected ? .green : .secondary)
                        Text(app.github.tokenStatus)
                    }
                    Text("Manage the token on the GitHub Issue screen. It lives only in the macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Ollama (local AI — no cloud fallback)") {
                    TextField("Ollama URL", text: $ollamaURL).textFieldStyle(.roundedBorder)
                    HStack {
                        Image(systemName: settings.ollamaOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(settings.ollamaOK ? .green : .red)
                        Text(settings.ollamaMessage).textSelection(.enabled)
                        Spacer()
                        Button("Refresh") { Task { await settings.refreshOllama() } }
                    }
                    Picker("Local model", selection: $ollamaModel) {
                        Text("— choose —").tag("")
                        ForEach(settings.ollamaModels) { Text("\($0.name)  (\($0.detail))").tag($0.name) }
                    }
                    Text("Tip: on machines with limited RAM use a small quantised model such as \(OllamaService.recommendedModelHint).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Appium") {
                    TextField("Appium server URL", text: $appiumURL).textFieldStyle(.roundedBorder)
                }

                Card(title: "Default Simulator") {
                    Picker("Device", selection: $defaultSimulator) {
                        ForEach(app.simulator.devices) { Text($0.displayName).tag($0.udid) }
                    }
                    Text("Default: iPhone 17 Pro · iOS 26.2 (\(Prefs.defaultSimulatorUDID))").font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Evidence storage") {
                    HStack {
                        Text(evidenceDirectory.isEmpty ? AppPaths.defaultEvidence.path : evidenceDirectory)
                            .textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { evidenceDirectory = url.path }
                        }
                        Button("Reset") { evidenceDirectory = "" }
                    }
                }

                Card(title: "Environment health") {
                    HStack {
                        Button { Task { await settings.refreshAll() } } label: { Label("Check dependencies", systemImage: "stethoscope") }
                        if settings.isChecking { ProgressView().controlSize(.small) }
                    }
                    ForEach(settings.dependencies) { dependency in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: dependency.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(dependency.ok ? .green : .red)
                                Text(dependency.name).font(.body.weight(.medium))
                                Text(dependency.detail).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if !dependency.ok {
                                Text("Install: \(dependency.installHint)").font(.caption.monospaced()).textSelection(.enabled)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    Text("Nothing is installed automatically — run the suggested commands yourself.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("Settings")
        .task { await settings.refreshAll() }
    }
}
