import Foundation
import JuicebarCore

/// Exercises only account control messages. Never sends prompts or starts a thread.
enum BundledCodexProbe {
    static func run(profile: String?, login: Bool, browserLogin: Bool, refresh: Bool, report: inout [String: Any], save: ([String: Any]) -> Void) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let home = profile.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        report["profile"] = profile == nil ? "isolated app container" : "explicitly selected profile"
        let diagnosticURL = support.appendingPathComponent("codex-diagnostic.txt")
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let diagnostic = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnostic.close() }
        let client = try ProcessClient(
            executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex"),
            arguments: ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false"],
            environment: ["CODEX_HOME": home.path], timeout: login ? 180 : 30, diagnosticOutput: diagnostic, workingDirectory: support)
        defer { client.close() }
        report["helper"] = "launched"
        func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
            var message: [String: Any] = ["id": id, "method": method]
            if let params { message["params"] = params }
            try client.send(message)
            let reply = try client.receive { $0["id"] as? Int == id }
            if let error = reply["error"] as? [String: Any] {
                // Do not persist arbitrary server messages, which may contain account details.
                throw NSError(domain: "CodexRPC.\(method)", code: error["code"] as? Int ?? -1)
            }
            return reply["result"] as? [String: Any] ?? [:]
        }
        let initialized = try request(1, "initialize", ["clientInfo": ["name": "juicebar_sandbox_probe", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
        report["initialized"] = initialized["userAgent"] is String
        try client.send(["method": "initialized"])
        if login {
            guard profile == nil else { throw NSError(domain: "Probe.LoginRequiresIsolatedProfile", code: 1) }
            let result = try request(2, "account/login/start", ["type": browserLogin ? "chatgpt" : "chatgptDeviceCode", "useHostedLoginSuccessPage": true])
            guard let url = result[browserLogin ? "authUrl" : "verificationUrl"] as? String else {
                throw NSError(domain: "Probe.InvalidLoginResponse", code: 1)
            }
            // Temporary local handoff only. Neither the device code nor tokens enter the report.
            let handoff = support.appendingPathComponent("codex-login.json")
            var handoffData = ["url": url]
            if let code = result["userCode"] as? String { handoffData["code"] = code }
            try JSONSerialization.data(withJSONObject: handoffData).write(to: handoff, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: handoff.path)
            defer { try? FileManager.default.removeItem(at: handoff) }
            report["login"] = "waiting for browser authorization"; save(report)
            let completed = try client.receive { $0["method"] as? String == "account/login/completed" }
            guard (completed["params"] as? [String: Any])?["success"] as? Bool == true else {
                throw NSError(domain: "Probe.LoginFailed", code: 1)
            }
            report["login"] = "completed"
        }
        guard !refresh || profile == nil else { throw NSError(domain: "Probe.RefreshRequiresIsolatedProfile", code: 1) }
        let account = try request(3, "account/read", ["refreshToken": refresh])
        report["refresh-requested"] = refresh
        let details = account["account"] as? [String: Any]
        report["signed-in"] = details != nil
        guard details != nil else { save(report); return }
        report["plan"] = details?["planType"] as? String ?? "unknown"
        let limits = try request(4, "account/rateLimits/read")
        let snapshot = try ProviderParsing.codex(limits, configuration: AccountConfiguration(provider: .codex), account: account)
        report["quota"] = "ok"
        report["windows"] = snapshot.windows.map { window -> [String: Any] in
            var value: [String: Any] = ["id": window.id, "usedPercent": window.usedPercent]
            if let reset = window.resetsAt { value["resetsAt"] = ISO8601DateFormatter().string(from: reset) }
            return value
        }
        if let count = snapshot.benefitCount { report["reset-offers"] = count }
        // A second read exercises continued operation without another process or login.
        _ = try request(5, "account/rateLimits/read")
        report["repeat-read"] = "ok"
        save(report)
    }
}
