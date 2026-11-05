import SwiftUI

struct SourceProjectView: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.Key.disableSigning) private var disableSigning = true

    var body: some View {
        @Bindable var source = app.source
        @Bindable var simulator = app.simulator
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Source folder") {
                        HStack {
                            Text(source.sourceURL?.path ?? "No folder selected").lineLimit(2).textSelection(.enabled)
                                .foregroundStyle(source.sourceURL == nil ? .secondary : .primary)
                            Spacer()
                            Button("Select Source Folder…") { source.chooseFolder() }
                        }
                        if source.isScanning { ProgressView("Scanning…").controlSize(.small) }
                        if let error = source.scanError { ErrorBanner(text: error) }
                        ForEach(source.preflightIssues, id: \.self) { InfoBanner(text: $0) }
                    }

                    if !source.containers.isEmpty {
                        Card(title: "Xcode project") {
                            Picker("Workspace / Project", selection: $source.selectedContainerID) {
                                ForEach(source.containers) { Text($0.displayName + "  —  " + relative($0.url, to: source.sourceURL)).tag($0.id) }
                            }
                            .onChange(of: source.selectedContainerID) { Task { await source.loadSchemes() } }
                            Picker("Scheme", selection: $source.selectedScheme) {
                                ForEach(source.schemes, id: \.self) { Text($0).tag($0) }
                            }
                            .onChange(of: source.selectedScheme) { Task { await source.refreshBundleIdentifier() } }
                            Picker("Configuration", selection: $source.selectedConfiguration) {
                                ForEach(source.configurations, id: \.self) { Text($0).tag($0) }
                            }
                            .onChange(of: source.selectedConfiguration) { Task { await source.refreshBundleIdentifier() } }
                            LabeledContent("Bundle identifier", value: source.isReadingBundle ? "Đang đọc từ build settings…" : (source.bundleIdentifier.isEmpty ? "—" : source.bundleIdentifier))
                                .textSelection(.enabled)
                            if source.targets.count > 1 {
                                Text("App targets: " + source.targets.map { "\($0.targetName) (\($0.bundleID))" }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Ad-hoc signing (no Apple team; keeps Keychain/login working)", isOn: $disableSigning)
                        }
                    }

                    Card(title: "Simulator target") {
                        Picker("Device", selection: $simulator.selectedUDID) {
                            ForEach(simulator.devices) { Text($0.displayName + ($0.isBooted ? "  ● Booted" : "")).tag($0.udid) }
                        }
                        if let error = simulator.error { ErrorBanner(text: error) }
                    }

                    Card(title: "Pipeline") {
                        StageRow(title: "1. Build (xcodebuild)", state: source.buildStage)
                        StageRow(title: "2. Boot Simulator", state: source.bootStage)
                        StageRow(title: "3. Install app", state: source.installStage)
                        StageRow(title: "4. Launch app", state: source.launchStage)
                        if let app = source.builtApp {
                            Text(app.appURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack {
                            if source.isBusy {
                                Button(role: .destructive) { source.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                            } else {
                                Button { source.start { _ = await $0.build(issueURL: app.testCases.plan?.issueURL ?? app.github.snapshot?.htmlURL) } } label: { Label("Build", systemImage: "hammer") }
                                    .disabled(!source.canBuild)
                                Button { source.start { _ = await $0.buildAndRun(issueURL: app.testCases.plan?.issueURL ?? app.github.snapshot?.htmlURL) } } label: { Label("Build & Run", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent).disabled(!source.canBuild)
                            }
                            if source.isBusy { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 460, idealWidth: 520)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Build log").font(.headline)
                    if source.buildStage.isRunning { Text(source.currentOperation).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if let path = source.lastBuildLogPath {
                        Button("Reveal log file") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }.controlSize(.small)
                    }
                }
                LogView(log: source.log, minHeight: 300)
            }
            .padding(20)
            .frame(minWidth: 380)
        }
        .navigationTitle("Source Project Setup")
    }

    private func relative(_ url: URL, to root: URL?) -> String {
        guard let root, url.path.hasPrefix(root.path) else { return url.path }
        return String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
