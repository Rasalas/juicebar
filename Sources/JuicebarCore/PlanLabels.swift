import Foundation

/// Provider plan identifiers, not multipliers inferred from consumption or remaining quota.
public enum PlanLabels {
    public static func codex(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "ChatGPT" }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pro", "pro_20x": return "Pro 20×"
        case "prolite", "pro_lite", "pro-lite", "pro lite", "pro_5x": return "Pro 5×"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    public static func claude(_ plan: String?, tier: String?) -> String {
        let label = plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard label.lowercased() == "max", let tier,
              let range = tier.range(of: #"^default_claude_max_[1-9][0-9]*x$"#, options: .regularExpression) else {
            return label.isEmpty ? "Claude-Abo" : label.capitalized
        }
        let multiplier = tier[range].dropFirst("default_claude_max_".count).dropLast()
        return "Max \(multiplier)×"
    }
}
