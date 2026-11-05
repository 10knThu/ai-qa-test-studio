import Foundation

struct SimulatorDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let osVersion: String      // "26.2"
    let runtimeIdentifier: String
    let state: String          // Shutdown / Booted / Booting ...

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var isIPhone: Bool { name.hasPrefix("iPhone") }
    var displayName: String { "\(name) — iOS \(osVersion)" }
}

/// Wraps `xcrun simctl`. Every call targets an explicit UDID (never `booted`).
final class SimulatorService {

    private struct SimctlList: Decodable {
        struct Raw: Decodable {
            let name: String
            let udid: String
            let state: String
            let isAvailable: Bool?
        }
        let devices: [String: [Raw]]
    }

    func listDevices() async throws -> [SimulatorDevice] {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], mergeStderr: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError("Could not run xcrun simctl: \(error.localizedDescription)",
                           recovery: "Install Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.")
        }
        guard result.succeeded, let data = JSONExtract.payload(from: result.output) else {
            throw AppError("`xcrun simctl list` failed: \(result.errorOutput.tailLines(3))",
                           recovery: "Open Xcode once to finish installing components, then retry.")
        }
        let list = try JSONDecoder().decode(SimctlList.self, from: data)
        var devices: [SimulatorDevice] = []
        for (runtime, raws) in list.devices {
            guard let version = Self.iOSVersion(fromRuntime: runtime) else { continue }
            for raw in raws where raw.isAvailable ?? true {
                devices.append(SimulatorDevice(udid: raw.udid, name: raw.name, osVersion: version,
                                               runtimeIdentifier: runtime, state: raw.state))
            }
        }
        guard !devices.isEmpty else {
            throw AppError("No available iOS Simulator devices were found.",
                           recovery: "Install an iOS runtime: Xcode ▸ Settings ▸ Components, or `xcodebuild -downloadPlatform iOS`.")
        }
        return devices.sorted {
            if $0.osVersion != $1.osVersion { return $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedDescending }
            return $0.name < $1.name
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-2" -> "26.2"; non-iOS runtimes -> nil.
    static func iOSVersion(fromRuntime runtime: String) -> String? {
        guard let tail = runtime.components(separatedBy: "SimRuntime.").last else { return nil }
        let parts = tail.split(separator: "-").map(String.init)
        guard parts.first == "iOS", parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: ".")
    }

    func refresh(_ udid: String) async throws -> SimulatorDevice? {
        try await listDevices().first { $0.udid == udid }
    }

    /// Boots (if needed), waits for boot completion and opens the Simulator app as a separate window.
    func bootAndOpen(udid: String, onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let current = try await refresh(udid)
        guard let current else {
            throw AppError("Simulator \(udid) is not available.", recovery: "Pick another Simulator or reinstall the runtime.")
        }
        if !current.isBooted {
            let boot = try await ProcessRunner.xcrun(["simctl", "boot", udid], onLine: onLine)
            // Exit 149 / "current state: Booted" means it was already booting/booted – not an error.
            if !boot.succeeded && !boot.output.contains("current state: Booted") && !boot.output.contains("current state: Booting") {
                throw AppError("Failed to boot \(current.name): \(boot.output.tailLines(3))",
                               recovery: "Check the iOS runtime is installed and healthy; try `xcrun simctl shutdown all` then retry.")
            }
        }
        onLine?("Waiting for \(current.name) to finish booting…")
        let status = try await ProcessRunner.xcrun(["simctl", "bootstatus", udid, "-b"], onLine: onLine)
        guard status.succeeded else {
            throw AppError("Simulator did not finish booting: \(status.output.tailLines(3))",
                           recovery: "Erase the device (`xcrun simctl erase \(udid)`) or restart CoreSimulatorService.")
        }
        let open = try await ProcessRunner.run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])
        guard open.succeeded else {
            throw AppError("Could not open the Simulator app: \(open.output.tailLines(2))")
        }
        onLine?("Simulator window opened.")
    }

    func install(udid: String, appURL: URL, onLine: (@Sendable (String) -> Void)? = nil) async throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw AppError("The built app does not exist at \(appURL.path).", recovery: "Build the project again.")
        }
        let result = try await ProcessRunner.xcrun(["simctl", "install", udid, appURL.path], onLine: onLine)
        guard result.succeeded else {
            throw AppError("App installation failed: \(result.output.tailLines(4))",
                           recovery: "Ensure the Simulator is booted and the app was built for the iOS Simulator SDK (not a device build).")
        }
    }

    /// Returns the launched process id when reported.
    @discardableResult
    func launch(udid: String, bundleID: String, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Int? {
        let result = try await ProcessRunner.xcrun(["simctl", "launch", "--terminate-running-process", udid, bundleID], onLine: onLine)
        guard result.succeeded else {
            throw AppError("App launch failed: \(result.output.tailLines(4))",
                           recovery: "Verify the bundle identifier \(bundleID) and that the app is installed on this Simulator.")
        }
        // Output looks like "com.example.app: 12345"
        return result.output.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func terminate(udid: String, bundleID: String) async throws {
        _ = try await ProcessRunner.xcrun(["simctl", "terminate", udid, bundleID])
    }

    func relaunch(udid: String, bundleID: String) async throws {
        try await terminate(udid: udid, bundleID: bundleID)
        try await launch(udid: udid, bundleID: bundleID)
    }

    func screenshot(udid: String, to url: URL) async throws {
        let result = try await ProcessRunner.xcrun(["simctl", "io", udid, "screenshot", url.path])
        guard result.succeeded else {
            throw AppError("Screenshot failed: \(result.output.tailLines(2))")
        }
    }
}
