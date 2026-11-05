import Foundation

/// Starts `appium` itself when it is installed but not running (a stopped server used to Block every case).
enum AppiumLauncher {
    @MainActor
    static func ensureRunning(url: URL, log: (String) -> Void) async {
        if await isReady(url) { return }
        guard let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return }
        guard let binary = locateBinary() else {
            log("Appium chưa chạy và không tìm thấy lệnh `appium` — cài bằng `npm i -g appium && appium driver install xcuitest`.")
            return
        }
        log("Appium chưa chạy — tự khởi động `\(binary) --port \(url.port ?? 4723)`…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--port", String(url.port ?? 4723)]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", environment["PATH"] ?? ""].joined(separator: ":")
        process.environment = environment
        let logURL = AppPaths.logs.appendingPathComponent("appium-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) { process.standardOutput = handle; process.standardError = handle }
        do { try process.run() } catch {
            log("Không khởi động được Appium: \(error.localizedDescription)")
            return
        }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 750_000_000)
            if await isReady(url) { log("Appium đã sẵn sàng."); return }
        }
        log("Appium chưa phản hồi sau 30s — xem \(logURL.path).")
    }

    private static func isReady(_ url: URL) async -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("status"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func locateBinary() -> String? {
        ["/usr/local/bin/appium", "/opt/homebrew/bin/appium", NSHomeDirectory() + "/.npm-global/bin/appium"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
