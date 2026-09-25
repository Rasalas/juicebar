import Foundation

public enum ProviderParsing {
    public static func costBucket(_ bucket: [String: Any], provider: ProviderKind) throws -> Double {
        guard let rows = bucket["results"] as? [[String: Any]] else { throw ProviderFailure.invalidData("Kostenbericht enthält keine lesbaren Ergebnisse.") }
        return try rows.reduce(0) { total, row in
            if provider == .openaiAPI {
                guard let amount = row["amount"] as? [String: Any], (amount["currency"] as? String)?.lowercased() == "usd", let value = JSONValue.amount(amount["value"]) else { throw ProviderFailure.invalidData("Unbekannte Währung oder Kosteneinheit.") }
                return total + value
            }
            guard provider == .anthropicAPI, (row["currency"] as? String)?.uppercased() == "USD", let cents = JSONValue.amount(row["amount"]) else { throw ProviderFailure.invalidData("Unbekannte Währung oder Kosteneinheit.") }
            return total + cents / 100
        }
    }
    public static func codex(_ payload: [String: Any], configuration: AccountConfiguration, account: [String: Any] = [:], now: Date = Date()) throws -> AccountSnapshot {
        let rawAccount = account["account"] as? [String: Any] ?? [:]
        let identityValue = payload["accountId"] as? String ?? rawAccount["email"] as? String ?? configuration.id
        var windows: [QuotaWindow] = []
        var buckets = payload["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let limits = payload["rateLimits"] as? [String: Any] { buckets[limits["limitId"] as? String ?? "codex"] = limits }
        var money: [MoneyMetric] = []
        for (bucketID, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            let name = bucket["limitName"] as? String
            for key in ["primary", "secondary"] {
                guard let raw = bucket[key] as? [String: Any] else { continue }
                guard let used = JSONValue.number(raw["usedPercent"]), used >= 0 else { throw ProviderFailure.invalidData("Codex liefert ein unbekanntes Limitformat.") }
                let duration = JSONValue.number(raw["windowDurationMins"]).map { $0 * 60 }
                let title = JSONValue.title(duration: duration, fallback: key == "primary" ? "Verbrauch" : "Weiteres Limit")
                windows.append(QuotaWindow(id: "\(bucketID).\(key)", title: name.map { "\($0) · \(title)" } ?? title,
                                           usedPercent: used, resetsAt: JSONValue.date(raw["resetsAt"]), duration: duration))
            }
            if let credit = bucket["credits"] as? [String: Any], let balance = JSONValue.amount(credit["balance"]) {
                // Provider credits are not USD. Their unit must remain visible.
                money.append(MoneyMetric(id: "\(bucketID).credits", title: "Guthaben", amount: balance, currency: "Credits"))
            }
        }
        let inventory = payload["rateLimitResetCredits"] as? [String: Any]
        let benefits = (inventory?["credits"] as? [[String: Any]] ?? []).compactMap { raw -> ResetBenefit? in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let status = BenefitStatus(rawValue: raw["status"] as? String ?? "") ?? .unknown
            return ResetBenefit(id: id, title: raw["title"] as? String ?? "Angesparter Reset", scope: "Codex-Limits",
                                expiresAt: JSONValue.date(raw["expiresAt"]), status: status)
        }
        let count = JSONValue.number(inventory?["availableCount"]).map(Int.init)
        guard !windows.isEmpty || inventory != nil || !money.isEmpty else {
            throw ProviderFailure.unsupported("Für diese Anmeldung sind keine Abo-Limits verfügbar. Für API-Kosten ein API-Konto hinzufügen.")
        }
        return AccountSnapshot(configurationID: configuration.id, identity: stableID("codex|\(identityValue)"),
                               plan: PlanLabels.codex(rawAccount["planType"] as? String ?? (payload["rateLimits"] as? [String: Any])?["planType"] as? String), observedAt: now, source: "Codex App Server",
                               windows: windows, benefits: benefits, benefitCount: count,
                               benefitsChecked: inventory?["credits"] is [[String: Any]], money: money)
    }

    public static func claude(_ payload: [String: Any], configuration: AccountConfiguration, now: Date = Date()) throws -> AccountSnapshot {
        guard payload["rate_limits_available"] as? Bool != false,
              let limits = payload["rate_limits"] as? [String: Any] else {
            throw ProviderFailure.unsupported("Claude meldet keine Abo-Limits. CLI-Anmeldung und Version prüfen.")
        }
        var windows: [QuotaWindow] = []
        for (key, value) in limits.sorted(by: { $0.key < $1.key }) {
            guard key != "extra_usage", key != "nimbus_quill", let raw = value as? [String: Any], raw["resets_at"] != nil,
                  let used = JSONValue.number(raw["utilization"]), used >= 0 else { continue }
            let duration: Double? = key == "five_hour" ? 18000 : key.hasPrefix("seven_day") ? 604800 : nil
            let title: String
            switch key {
            case "five_hour": title = "5 Stunden"
            case "seven_day": title = "Woche"
            case "seven_day_opus": title = "Opus · Woche"
            case "seven_day_sonnet": title = "Sonnet · Woche"
            default: title = key.replacingOccurrences(of: "_", with: " ").capitalized
            }
            windows.append(QuotaWindow(id: key, title: title, usedPercent: used,
                                       resetsAt: JSONValue.date(raw["resets_at"]), duration: duration, supportsPace: duration != nil))
        }
        for raw in limits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = raw["display_name"] as? String, let used = JSONValue.number(raw["utilization"]), used >= 0 else { continue }
            windows.append(QuotaWindow(id: "model.\(name)", title: "\(name) · Woche", usedPercent: used,
                                       resetsAt: JSONValue.date(raw["resets_at"]), duration: 604800))
        }
        guard !windows.isEmpty else { throw ProviderFailure.invalidData("Claude hat keine lesbaren Limitwerte geliefert.") }
        return AccountSnapshot(configurationID: configuration.id,
                               identity: stableID("claude|\(configuration.profileDirectory)|\(configuration.id)"),
                               plan: PlanLabels.claude(payload["subscription_type"] as? String, tier: payload["rate_limit_tier"] as? String), observedAt: now,
                               source: "Claude Code · get_usage", windows: windows,
                               notice: "Reset-Angebote sind noch nicht verfügbar. Ein Ablaufdatum kann manuell ergänzt werden.")
    }

    public static func claudeBenefits(_ payload: [String: Any], now: Date = Date()) -> (benefits: [ResetBenefit], count: Int)? {
        guard let program = payload["cedar_ember"] as? [String: Any], let grants = program["grants"] as? [[String: Any]] else { return nil }
        let benefits = grants.compactMap { grant -> ResetBenefit? in
            guard let id = grant["id"] as? String, let count = JSONValue.number(grant["resets_left"]), count >= 0 else { return nil }
            let expiry = JSONValue.date(grant["ends_at"])
            let status: BenefitStatus = count == 0 ? .used : (expiry.map { $0 <= now } ?? false) ? .expired :
                (grant["paused"] as? Bool == true || grant["usable_now"] as? Bool == false) ? .paused : .available
            return ResetBenefit(id: id, title: "Reset-Angebot", scope: "Geltungsbereich beim Anbieter prüfen", count: Int(count), expiresAt: expiry, status: status)
        }
        return (benefits, benefits.filter { $0.status == .available }.reduce(0) { $0 + $1.count })
    }

    public static func openCodeGo(_ payload: [String: Any], configuration: AccountConfiguration, identity: String, now: Date = Date()) throws -> AccountSnapshot {
        guard let usage = payload["usage"] as? [String: Any] else { throw ProviderFailure.invalidData("OpenCode Go liefert ein unbekanntes Antwortformat.") }
        let windows: [QuotaWindow] = usage.sorted(by: { $0.key < $1.key }).compactMap { key, value in
            guard let raw = value as? [String: Any], let percent = JSONValue.number(raw["percent"]), percent >= 0 else { return nil }
            let title = ["rolling": "5 Stunden", "weekly": "Woche", "monthly": "Monat"][key] ?? key.capitalized
            let duration: Double? = key == "weekly" ? 604800 : nil
            return QuotaWindow(id: key, title: title, usedPercent: percent, resetsAt: JSONValue.date(raw["resetsAt"]),
                               duration: duration, supportsPace: key == "weekly")
        }
        guard !windows.isEmpty else { throw ProviderFailure.invalidData("OpenCode Go hat keine lesbaren Limitwerte geliefert.") }
        return AccountSnapshot(configurationID: configuration.id, identity: identity, plan: "Go", observedAt: now,
                               source: "OpenCode Go", windows: windows)
    }
}
