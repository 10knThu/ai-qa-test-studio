import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var dependencies: [DependencyStatus] = []
    var isChecking = false
    var ollamaModels: [OllamaModel] = []
    var ollamaMessage = "Not checked"
    var ollamaOK = false

    func refreshAll() async {
        isChecking = true
        defer { isChecking = false }
        async let deps = DependencyChecker().checkAll()
        await refreshOllama()
        dependencies = await deps
    }

    func refreshOllama() async {
        let service = OllamaService()
        do {
            let version = try await service.version()
            ollamaModels = try await service.models()
            ollamaOK = true
            ollamaMessage = "Ollama v\(version) running — \(ollamaModels.count) model(s) installed"
            if ollamaModels.isEmpty {
                ollamaOK = false
                ollamaMessage = "Ollama is running but has no models. Run `ollama pull \(OllamaService.recommendedModelHint)`."
            } else if !ollamaModels.contains(where: { $0.name == Prefs.ollamaModel }) {
                // Default to the smallest installed model (friendly to limited CPU/RAM).
                let smallest = ollamaModels.min { $0.sizeBytes < $1.sizeBytes }
                UserDefaults.standard.set(smallest?.name ?? "", forKey: Prefs.Key.ollamaModel)
            }
        } catch {
            ollamaModels = []
            ollamaOK = false
            ollamaMessage = error.userText
        }
    }
}
