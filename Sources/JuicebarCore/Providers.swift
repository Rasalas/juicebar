import Foundation

public protocol UsageProvider: Sendable {
    func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot
}

public struct ProviderRegistry: Sendable {
    public init() {}
    public func provider(for kind: ProviderKind) -> any UsageProvider {
        switch kind {
        case .codex: return CodexProvider()
        case .claude: return ClaudeProvider()
        default: return APIProvider()
        }
    }
}

public struct CodexProvider: UsageProvider {
    public init() {}
    public func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot {
        let task = Task.detached(priority: .utility) {
            var env: [String: String] = [:]
            if !configuration.profileDirectory.isEmpty { env["CODEX_HOME"] = NSString(string: configuration.profileDirectory).expandingTildeInPath }
            let client = try ProcessClient(executable: ProcessClient.executable("codex", custom: configuration.executablePath),
                                           arguments: ["app-server", "--stdio"], environment: env, timeout: 18)
            defer { client.close() }
            func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
                var object: [String: Any] = ["id": id, "method": method]; if let params { object["params"] = params }
                try client.send(object)
                let reply = try client.receive { ($0["id"] as? Int) == id }
                if let error = reply["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    if message.contains("auth") || message.contains("login") || message.contains("sign in") { throw ProviderFailure.authentication }
                    throw ProviderFailure.unsupported(tr("Codex unterstützt diese Abfrage nicht. CLI-Version und Anmeldung prüfen."))
                }
                return reply["result"] as? [String: Any] ?? [:]
            }
            _ = try request(1, "initialize", ["clientInfo": ["name": "juicebar", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
            try client.send(["method": "initialized"])
            let account = try request(2, "account/read", ["refreshToken": false])
            let limits = try request(3, "account/rateLimits/read")
            var snapshot = try ProviderParsing.codex(limits, configuration: configuration, account: account)
            if includeHistory, let history = try? request(4, "account/usage/read"), let days = history["dailyUsageBuckets"] as? [[String: Any]] {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
                snapshot.dailyUsage = days.compactMap { raw in
                    guard let day = raw["startDate"] as? String, let date = formatter.date(from: day), let tokens = JSONValue.number(raw["tokens"]) else { return nil }
                    guard date >= Date().addingTimeInterval(-30 * 86400) else { return nil }
                    return UsageDay(day: date, tokens: tokens)
                }.sorted { $0.day < $1.day }
            }
            return snapshot
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public struct ClaudeProvider: UsageProvider {
    public init() {}
    public func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot {
        let task = Task.detached(priority: .utility) {
            var env = ["ENABLE_CLAUDEAI_MCP_SERVERS": "false", "CLAUDE_CODE_AUTO_CONNECT_IDE": "0", "CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL": "1", "FORCE_CODE_TERMINAL": "", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]
            if !configuration.profileDirectory.isEmpty { env["CLAUDE_CONFIG_DIR"] = NSString(string: configuration.profileDirectory).expandingTildeInPath }
            let args = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""]
            let client = try ProcessClient(executable: ProcessClient.executable("claude", custom: configuration.executablePath), arguments: args, environment: env, timeout: 20)
            defer { client.close() }
            func request(_ id: String, _ body: [String: Any]) throws -> [String: Any] {
                try client.send(["type": "control_request", "request_id": id, "request": body])
                let reply: [String: Any]
                do { reply = try client.receive { ($0["type"] as? String) == "control_response" && (($0["response"] as? [String: Any])?["request_id"] as? String) == id } }
                catch ProviderFailure.timedOut {
                    if id == "init" { throw ProviderFailure.needsSetup(tr("Claude startet nicht innerhalb von 20 Sekunden. Automatische Versuche pausieren; CLI-Anmeldung und macOS-Zugriff prüfen, dann manuell aktualisieren.")) }
                    throw ProviderFailure.timedOut
                }
                guard let response = reply["response"] as? [String: Any], response["subtype"] as? String == "success" else {
                    throw ProviderFailure.unsupported(tr("Claude unterstützt get_usage nicht oder ist nicht angemeldet. Die aktuelle CLI und ihre Anmeldung prüfen."))
                }
                return response["response"] as? [String: Any] ?? [:]
            }
            _ = try request("init", ["subtype": "initialize", "hooks": [:]])
            var snapshot = try ProviderParsing.claude(request("usage", ["subtype": "get_usage", "skip_behaviors": true]), configuration: configuration)
            if let account = Self.localAccount(configuration: configuration) {
                if let id = account["accountUuid"] as? String {
                    snapshot.identity = stableID("claude|\(id)|\(account["organizationUuid"] as? String ?? "")")
                }
                let tier = account["userRateLimitTier"] as? String ?? account["organizationRateLimitTier"] as? String
                snapshot.plan = PlanLabels.claude(snapshot.plan, tier: tier)
            }
            return snapshot
        }
        var snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        // Supplementary reset offers never trigger a Keychain prompt or refresh a CLI-owned token.
        if configuration.useLocalCredentials, let token = Self.localOAuthToken(configuration: configuration) {
            if let payload = try? await HTTPTransport.get(URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!, headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]),
               let inventory = ProviderParsing.claudeBenefits(payload) {
                snapshot.benefits = inventory.benefits; snapshot.benefitCount = inventory.count
                snapshot.benefitsChecked = true; snapshot.notice = nil
            }
        }
        return snapshot
    }
    private static func localOAuthToken(configuration: AccountConfiguration) -> String? {
        let fm = FileManager.default
        let directory = configuration.profileDirectory.isEmpty ? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude") : URL(fileURLWithPath: NSString(string: configuration.profileDirectory).expandingTildeInPath)
        var text: String?
        let url = directory.appendingPathComponent(".credentials.json")
        if let attributes = try? fm.attributesOfItem(atPath: url.path), (attributes[.size] as? Int ?? 0) < 100_000 { text = try? String(contentsOf: url, encoding: .utf8) }
        if text == nil && configuration.profileDirectory.isEmpty { text = SecretStore.read(service: "Claude Code-credentials") }
        guard let text, let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let auth = raw["claudeAiOauth"] as? [String: Any], let token = auth["accessToken"] as? String else { return nil }
        if let expiry = JSONValue.number(auth["expiresAt"]), expiry / 1000 < Date().timeIntervalSince1970 { return nil }
        return token
    }
    private static func localAccount(configuration: AccountConfiguration) -> [String: Any]? {
        let root = FileManager.default.homeDirectoryForCurrentUser
        let url = configuration.profileDirectory.isEmpty ? root.appendingPathComponent(".claude.json") : URL(fileURLWithPath: NSString(string: configuration.profileDirectory).expandingTildeInPath).appendingPathComponent(".claude.json")
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size < 2_000_000,
              let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account
    }
}

public struct APIProvider: UsageProvider {
    public init() {}
    public func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot {
        if configuration.provider == .opencodeZen {
            return AccountSnapshot(configurationID: configuration.id, identity: configuration.id, plan: "Zen", source: tr("Lokale OpenCode-Nutzung"),
                                   notice: tr("Zen bietet hier noch keine verifizierte Guthabenquelle. Tokens und geschätzte Kosten stehen unter Nutzung."))
        }
        let token = SecretStore.read(account: configuration.id) ?? (configuration.useLocalCredentials ? Self.openCodeKey(configuration.provider) : nil)
        guard let token, !token.isEmpty else { throw ProviderFailure.authentication }
        let identity = stableID("\(configuration.provider.rawValue)|\(token)")
        let headers = ["Authorization": "Bearer \(token)"]
        if configuration.provider == .opencodeGo {
            let payload = try await HTTPTransport.get(URL(string: "https://opencode.ai/zen/go/v1/usage")!, headers: headers)
            return try ProviderParsing.openCodeGo(payload, configuration: configuration, identity: identity)
        }
        if configuration.provider == .openrouter {
            let payload = try await HTTPTransport.get(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers)
            guard let data = payload["data"] as? [String: Any], let credits = JSONValue.number(data["total_credits"]),
                  let used = JSONValue.number(data["total_usage"]) else { throw ProviderFailure.invalidData(tr("OpenRouter liefert ein unbekanntes Guthabenformat.")) }
            return AccountSnapshot(configurationID: configuration.id, identity: identity, source: "OpenRouter Credits",
                                   money: [MoneyMetric(id: "balance", title: tr("Guthaben"), amount: credits - used), MoneyMetric(id: "lifetime", title: tr("Gesamtausgaben"), amount: used)])
        }
        return try await costs(configuration: configuration, token: token, identity: identity)
    }
    public static var hasLocalOpenCodeGoKey: Bool { !(openCodeKey(.opencodeGo) ?? "").isEmpty }
    private static func openCodeKey(_ kind: ProviderKind) -> String? {
        guard kind == .opencodeGo || kind == .opencodeZen else { return nil }
        let fm = FileManager.default
        let root = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        let url = URL(fileURLWithPath: root).appendingPathComponent("opencode/auth.json")
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size < 1_000_000,
              let data = try? Data(contentsOf: url), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = raw[kind == .opencodeGo ? "opencode-go" : "opencode"] as? [String: Any], auth["type"] as? String == "api" else { return nil }
        return auth["key"] as? String
    }
    private func costs(configuration: AccountConfiguration, token: String, identity: String) async throws -> AccountSnapshot {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(), start = calendar.dateInterval(of: .month, for: now)!.start
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        var components = URLComponents(string: configuration.provider == .openaiAPI ? "https://api.openai.com/v1/organization/costs" : "https://api.anthropic.com/v1/organizations/cost_report")!
        let iso = ISO8601DateFormatter()
        components.queryItems = configuration.provider == .openaiAPI ? [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))), URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")] : [URLQueryItem(name: "starting_at", value: iso.string(from: start)), URLQueryItem(name: "ending_at", value: iso.string(from: now)), URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
        let headers = configuration.provider == .openaiAPI ? ["Authorization": "Bearer \(token)"] : ["x-api-key": token, "anthropic-version": "2023-06-01"]
        var total = 0.0, daily: [UsageDay] = [], page: String?
        for index in 0..<10 {
            var url = components
            if let page { url.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            let payload = try await HTTPTransport.get(url.url!, headers: headers)
            guard let buckets = payload["data"] as? [[String: Any]] else { throw ProviderFailure.invalidData(tr("Der Anbieter liefert ein unbekanntes Kostenformat.")) }
            for bucket in buckets {
                let cost = try ProviderParsing.costBucket(bucket, provider: configuration.provider)
                total += cost
                if let day = JSONValue.date(bucket["start_time"] ?? bucket["starting_at"]) { daily.append(UsageDay(day: day, tokens: 0, cost: cost)) }
            }
            if payload["has_more"] as? Bool != true { break }
            page = payload["next_page"] as? String
            guard page != nil, index < 9 else { throw ProviderFailure.invalidData(tr("Kostenbericht ist zu groß oder unvollständig.")) }
        }
        var windows: [QuotaWindow] = []
        if let budget = configuration.monthlyBudget, budget > 0 {
            windows.append(QuotaWindow(id: "budget", title: tr("Eigenes Monatsbudget"), usedPercent: total / budget * 100, resetsAt: end, duration: end.timeIntervalSince(start)))
        }
        return AccountSnapshot(configurationID: configuration.id, identity: identity, plan: tr("API · Organisation"), source: tr("Abrechnung des Anbieters"), windows: windows,
                               money: [MoneyMetric(id: "month", title: tr("Dieser Monat"), amount: total)], dailyUsage: daily, notice: tr("Abrechnungsdaten können zeitverzögert eintreffen. Monat nach UTC."))
    }
}
