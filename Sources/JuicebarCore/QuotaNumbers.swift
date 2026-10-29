import Foundation

/// Quota windows last one second to ten years; dates stay in years 1970 through 9999.
/// Percentages deliberately have no 100% ceiling: API budgets can be overspent.
public enum QuotaNumbers {
    public static let maximumDuration: TimeInterval = 10 * 366 * 86400
    public static func isPercent(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    public static func duration(_ value: Double?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 1, value <= maximumDuration else { return nil }
        return value
    }
    public static func date(_ value: Date?) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(value.timeIntervalSince1970) else { return nil }
        return value
    }
    public static func count(_ value: Double?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return Int(exactly: value)
    }
    /// Keep overruns visible without narrowing externally supplied numbers to Int.
    public static func integerText(_ value: Double) -> String {
        guard value.isFinite else { return tr("unbekannt") }
        let rounded = value.rounded(.towardZero)
        if let integer = Int(exactly: rounded) { return String(integer) }
        return String(format: "%.3g", rounded)
    }
    public static func budgetPercent(spend: Double, budget: Double) throws -> Double {
        guard isPercent(spend), budget.isFinite, budget > 0 else {
            throw ProviderFailure.invalidData(tr("Unbekanntes Budget- oder Kostenformat."))
        }
        // Prefer division first, but recover a tiny ratio that would underflow before scaling.
        let ratio = spend / budget
        let percent = ratio == 0 && spend > 0 ? spend * 100 / budget : ratio * 100
        guard isPercent(percent) else { throw ProviderFailure.invalidData(tr("Unbekanntes Budget- oder Kostenformat.")) }
        return percent
    }
}
