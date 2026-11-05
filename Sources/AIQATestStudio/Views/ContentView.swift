import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $app.selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("Local-first · GitHub read-only")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        } detail: {
            switch app.selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .github: GitHubImportView()
            case .history: HistoryView()
            case .testCases: TestCasesView()
            case .source: SourceProjectView()
            case .simulator: SimulatorSetupView()
            case .runner: TestRunnerView()
            case .flows: FlowsView()
            case .reports: ReportsView()
            case .settings: SettingsView()
            }
        }
    }
}
