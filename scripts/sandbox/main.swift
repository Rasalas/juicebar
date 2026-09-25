import AppKit
import Foundation
import Security
import JuicebarCore

// Standalone feasibility app. Never writes provider credentials or the Juicebar database.
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? { arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
let realHome = argument("--home") ?? NSHomeDirectory()
let reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("probe-report.json")
var grants: [URL] = []
if arguments.contains("--grant") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching(); app.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = "Juicebar sandbox test: select provider folders"
    panel.message = "Select only the provider profile, executable, OpenCode data or SSH folders to test. The probe stores bookmarks, never credentials."
    panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
    panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: argument("--folder") ?? realHome)
    if panel.runModal() == .OK {
        let bookmarks = panel.urls.compactMap { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set((UserDefaults.standard.array(forKey: "grants") as? [Data] ?? []) + bookmarks, forKey: "grants")
    }
}
for data in UserDefaults.standard.array(forKey: "grants") as? [Data] ?? [] {
    var stale = false
    if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), !stale, url.startAccessingSecurityScopedResource() { grants.append(url) }
}
Task {
    var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, "grants": grants.count]
    for (name, path) in [("codex-profile", ".codex/auth.json"), ("claude-history", ".claude/projects"), ("claude-metadata", ".claude.json"), ("opencode-database", ".local/share/opencode/opencode.db"), ("opencode-auth", ".local/share/opencode/auth.json"), ("ssh-config", ".ssh/config")] {
        let url = URL(fileURLWithPath: realHome).appendingPathComponent(path)
        do {
            if name == "claude-history" { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            else { let file = try FileHandle(forReadingFrom: url); try file.close() }
            report[name] = "readable"
        } catch { report[name] = "blocked: \((error as NSError).domain) \((error as NSError).code)" }
    }
    SecKeychainSetUserInteractionAllowed(false)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var credential: CFTypeRef?
    report["claude-keychain-status"] = SecItemCopyMatching(query as CFDictionary, &credential)
    credential = nil
    if let path = argument("--codex") {
        do { let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); try file.close(); report["codex-binary-read"] = "readable" }
        catch { report["codex-binary-read"] = "blocked" }
        do {
            let client = try ProcessClient(executable: URL(fileURLWithPath: path), arguments: ["--version"], timeout: 3)
            client.close(); report["codex-exec"] = "launched"
        } catch { report["codex-exec"] = "blocked: \((error as NSError).domain) \((error as NSError).code)" }
    }
    let goURL = URL(fileURLWithPath: realHome).appendingPathComponent(".local/share/opencode/auth.json")
    if let bytes = try? Data(contentsOf: goURL), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
       let go = json["opencode-go"] as? [String: Any], let token = go["key"] as? String {
        do {
            let result = try await HTTPTransport.get(URL(string: "https://opencode.ai/zen/go/v1/usage")!, headers: ["Authorization": "Bearer \(token)"])
            let config = AccountConfiguration(provider: .opencodeGo)
            let snapshot = try ProviderParsing.openCodeGo(result, configuration: config, identity: "probe")
            report["opencode-quota"] = "ok: \(snapshot.windows.count) windows"
        } catch { report["opencode-quota"] = "failed: \((error as NSError).domain)" }
    }
    if let history = try? OpenCodeHistory.read(path: realHome + "/.local/share/opencode/opencode.db") { report["opencode-history"] = "ok: \(history.days.count) days" }
    for kind in [ProviderKind.codex, .claude] {
        var config = AccountConfiguration(provider: kind)
        config.profileDirectory = realHome + (kind == .codex ? "/.codex" : "/.claude")
        config.executablePath = argument(kind == .codex ? "--codex" : "--claude") ?? ""
        config.useLocalCredentials = false
        do {
            let snapshot = try await ProviderRegistry().provider(for: kind).read(configuration: config, includeHistory: false)
            report[kind.rawValue + "-quota"] = "ok: \(snapshot.windows.count) windows"
        } catch { report[kind.rawValue + "-quota"] = error.localizedDescription }
    }
    if let host = argument("--ssh") {
        do {
            let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "--", host, "echo '{\"ok\":true}'"], timeout: 8)
            defer { client.close() }
            _ = try client.receive { $0["ok"] as? Bool == true }
            report["ssh"] = "ok"
        } catch { report["ssh"] = error.localizedDescription }
    }
    do {
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        print(reportURL.path)
    } catch { fputs("Cannot save probe report\n", stderr) }
    grants.forEach { $0.stopAccessingSecurityScopedResource() }
    exit(0)
}
dispatchMain()
