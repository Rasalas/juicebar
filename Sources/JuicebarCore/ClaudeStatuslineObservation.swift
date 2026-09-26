import Foundation
import CoreFoundation

/// A credential-free local handoff from Claude Code's documented statusLine.
/// receivedAt is the local export time, not a promise of a fresh server poll.
public struct ClaudeStatuslineObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receivedAt: Date
    public let windows: [QuotaWindow]

    public static func capture(_ data: Data, now: Date = Date()) throws -> Self? {
        guard data.count <= 262_144,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFailure.invalidData("Invalid status line payload")
        }
        guard let limits = raw["rate_limits"] as? [String: Any] else { return nil }
        let definitions: [(String, String, TimeInterval)] = [
            ("five_hour", "5 Stunden", 5 * 3600), ("seven_day", "Woche", 7 * 86400)
        ]
        let windows = definitions.compactMap { key, title, duration -> QuotaWindow? in
            guard let value = limits[key] as? [String: Any],
                  let used = number(value["used_percentage"]), (0...100).contains(used),
                  let reset = number(value["resets_at"]), reset > now.timeIntervalSince1970,
                  reset <= now.timeIntervalSince1970 + duration + 3600 else { return nil }
            return QuotaWindow(id: "claude.\(key)", title: title, usedPercent: used,
                               resetsAt: Date(timeIntervalSince1970: reset), duration: duration)
        }
        // Missing data must not erase the last useful observation. The reader
        // independently excludes expired windows, even when the CLI is stopped.
        guard !windows.isEmpty else { return nil }
        return Self(schemaVersion: 1, receivedAt: now, windows: windows)
    }

    public static func read(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 16_384 else { throw ProviderFailure.invalidData("Status line export is too large") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(Self.self, from: data)
        guard observation.schemaVersion == 1, observation.receivedAt <= now.addingTimeInterval(60),
              observation.windows.count <= 2,
              Set(observation.windows.map(\.id)).count == observation.windows.count,
              observation.windows.allSatisfy({ ["claude.five_hour", "claude.seven_day"].contains($0.id) && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt != nil }) else {
            throw ProviderFailure.invalidData("Invalid status line export")
        }
        return observation
    }

    public func activeWindows(at now: Date = Date()) -> [QuotaWindow] {
        windows.filter { ($0.resetsAt ?? .distantPast) > now }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
