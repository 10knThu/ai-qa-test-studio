import SwiftUI
import SwiftData
import AppKit

@main
struct AIQATestStudioApp: App {
    @State private var appState = AppState()

    init() {
        // Needed when launched from `swift run` / Xcode without an app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("AI QA Test Studio") {
            ContentView()
                .environment(appState)
                .modelContainer(appState.container)
                .frame(minWidth: 1180, minHeight: 720)
                .task {
                    NSApp.activate(ignoringOtherApps: true)
                    await appState.bootstrap()
                }
        }
        .defaultSize(width: 1380, height: 860)
    }
}
