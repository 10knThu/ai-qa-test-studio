import Foundation
import Observation

@MainActor
@Observable
final class SimulatorViewModel {
    let service = SimulatorService()
    let log = LogStore()

    var devices: [SimulatorDevice] = []
    var selectedUDID: String = ""
    var isLoading = false
    var error: String?
    var bootStage: StageState = .idle

    var selected: SimulatorDevice? { devices.first { $0.udid == selectedUDID } }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await service.listDevices()
            error = nil
            if selected == nil { selectedUDID = Self.defaultDevice(in: devices)?.udid ?? "" }
        } catch {
            devices = []
            self.error = error.userText
        }
    }

    /// Default: the configured UDID (iPhone 17 Pro, iOS 26.2) → that model on the newest iOS → newest iPhone.
    static func defaultDevice(in devices: [SimulatorDevice]) -> SimulatorDevice? {
        if let preferred = devices.first(where: { $0.udid == Prefs.defaultSimulator }) { return preferred }
        if let match = devices.first(where: { $0.name == "iPhone 17 Pro" && $0.osVersion == "26.2" }) { return match }
        return devices.first(where: \.isIPhone) ?? devices.first
    }

    @discardableResult
    func boot() async -> Bool {
        guard let device = selected else {
            bootStage = .failed("No Simulator selected.")
            return false
        }
        bootStage = .running("Booting \(device.name)…")
        log.append("▶ Boot \(device.displayName) [\(device.udid)]")
        let service = self.service
        do {
            try await log.capture { emit in try await service.bootAndOpen(udid: device.udid, onLine: emit) }
            await refresh()
            bootStage = .succeeded("\(device.name) booted — Simulator window opened")
            return true
        } catch is CancellationError {
            bootStage = .cancelled
            return false
        } catch {
            bootStage = .failed(error.userText)
            log.append(error.userText, level: .error)
            return false
        }
    }
}
