import Foundation
import Darwin

/// Offline packaging check only. Does not initialize the SDK, log in or read quotas.
enum BundledClaudeLaunchProbe {
    static func run(report: inout [String: Any]) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let home = support.appendingPathComponent("claude-launch-only", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claude")
        process.arguments = ["--version"]
        process.currentDirectoryURL = home
        // No inherited provider keys, user profile or project configuration.
        process.environment = ["HOME": home.path, "PWD": home.path,
                               "CLAUDE_CONFIG_DIR": home.path, "PATH": "/usr/bin:/bin",
                               "DISABLE_AUTOUPDATER": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        report["process-started"] = true
        if finished.wait(timeout: .now() + 10) == .timedOut {
            report["timeout"] = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        guard !process.isRunning else { return }
        report["termination"] = process.terminationReason == .exit ? "exit" : "signal"
        report["status"] = process.terminationStatus
        report["version-command-ok"] = process.terminationReason == .exit && process.terminationStatus == 0
    }
}
