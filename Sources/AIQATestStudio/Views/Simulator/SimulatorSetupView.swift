import SwiftUI

struct SimulatorSetupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var simulator = app.simulator
        let source = app.source
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Available Simulators").font(.headline)
                    Spacer()
                    Button { Task { await simulator.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                if let error = simulator.error { ErrorBanner(text: error) }
                Table(simulator.devices, selection: Binding(get: { simulator.selectedUDID.isEmpty ? nil : simulator.selectedUDID },
                                                            set: { simulator.selectedUDID = $0 ?? "" })) {
                    TableColumn("Device") { Text($0.name) }
                    TableColumn("iOS") { Text($0.osVersion) }.width(60)
                    TableColumn("State") { device in
                        Label(device.state, systemImage: device.isBooted ? "circle.fill" : "circle")
                            .foregroundStyle(device.isBooted ? .green : .secondary)
                    }.width(110)
                    TableColumn("UDID") { Text($0.udid).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .padding(20).frame(minWidth: 480)

            VStack(alignment: .leading, spacing: 12) {
                Card(title: simulator.selected?.displayName ?? "No Simulator selected") {
                    StageRow(title: "Boot", state: simulator.bootStage)
                    StageRow(title: "Install", state: source.installStage)
                    StageRow(title: "Launch", state: source.launchStage)
                    Text(source.builtApp.map { "App: \($0.productName) · \($0.bundleID)" } ?? "No built app yet — build it in Source Project.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button { Task { await simulator.boot() } } label: { Label("Boot Simulator", systemImage: "power") }
                            .disabled(simulator.selected == nil)
                        Button { source.start { _ = await $0.install() } } label: { Label("Install App", systemImage: "square.and.arrow.down") }
                            .disabled(source.builtApp == nil || simulator.selected?.isBooted != true || source.isBusy)
                        Button { source.start { _ = await $0.launch() } } label: { Label("Launch App", systemImage: "play") }
                            .disabled(!source.installStage.isSucceeded || source.isBusy)
                    }
                    Text("The Simulator opens as its own macOS window (no embedded preview).").font(.caption).foregroundStyle(.secondary)
                }
                LogView(log: source.log, minHeight: 200)
            }
            .padding(20).frame(minWidth: 380)
        }
        .navigationTitle("Simulator Setup")
    }
}
