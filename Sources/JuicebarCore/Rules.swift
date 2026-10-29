import Foundation
import CryptoKit

public func stableID(_ value: String) -> String {
    var value = value
    return value.withUTF8 { hexDigest(UnsafeRawBufferPointer($0)) }
}

/// Lowercase SHA-256 hex. Persisted IDs depend on this exact output.
func hexDigest(_ bytes: UnsafeRawBufferPointer) -> String {
    let digest = SHA256.hash(data: bytes)
    return String(unsafeUninitializedCapacity: 64) { buffer in
        let digits: StaticString = "0123456789abcdef"
        var index = 0
        for byte in digest {
            buffer[index] = digits.utf8Start[Int(byte >> 4)]; buffer[index + 1] = digits.utf8Start[Int(byte & 15)]
            index += 2
        }
        return 64
    }
}

public struct UsageProjection: Equatable, Sendable {
    public var percentPerHour: Double
    public var reachesLimitAt: Date
}

public struct WarningEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case threshold, pace, forecast, expiry }
    public var id: String
    public var accountID: String
    public var kind: Kind
    public var title: String
    public var message: String
    public var createdAt: Date
    public init(id: String, accountID: String, kind: Kind, title: String, message: String, createdAt: Date) {
        self.id = id; self.accountID = accountID; self.kind = kind; self.title = title; self.message = message; self.createdAt = createdAt
    }
}

public enum WarningEngine {
    public static func projection(window: QuotaWindow, snapshot: AccountSnapshot, history: [AccountSnapshot], now: Date) -> UsageProjection? {
        guard window.hasValidUsage, snapshot.isFresh(at: now), window.supportsPace, let reset = window.resetsAt, reset > now, window.usedPercent < 100 else { return nil }
        var points: [(Date, Double)] = history.compactMap { sample in
            guard sample.identity == snapshot.identity, sample.configurationID == snapshot.configurationID,
                  now.timeIntervalSince(sample.observedAt) <= 3600, sample.observedAt <= snapshot.observedAt,
                  let w = sample.windows.first(where: { $0.id == window.id }),
                  QuotaPeriod.matches(window: window, snapshot: snapshot, otherWindow: w, otherSnapshot: sample) else { return nil }
            return (sample.observedAt, w.usedPercent)
        }
        points.append((snapshot.observedAt, window.usedPercent))
        points = Dictionary(points.map { ($0.0, $0.1) }, uniquingKeysWith: { _, new in new }).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        // A long unobserved interval cannot describe the current pace. Start again after the last gap.
        if let restart = points.indices.dropFirst().last(where: { points[$0].0.timeIntervalSince(points[$0 - 1].0) > 600 }) {
            points = Array(points[restart...])
        }
        guard points.count >= 3, let first = points.first, let last = points.last,
              last.0.timeIntervalSince(first.0) >= 300, last.1 > first.1 else { return nil }
        var lastIncrease = first.0
        for index in 1..<points.count {
            guard points[index].1 >= points[index - 1].1 else { return nil }
            if points[index].1 > points[index - 1].1 { lastIncrease = points[index].0 }
        }
        guard now.timeIntervalSince(lastIncrease) <= 600 else { return nil }
        // Average interval rates with a ten-minute half-life. Integrating weights over elapsed
        // time includes observed idle periods and avoids giving frequent polls extra influence.
        let decay = log(2.0) / 600
        var weightedRate = 0.0, totalWeight = 0.0
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            let seconds = current.0.timeIntervalSince(previous.0)
            let weight = exp(-now.timeIntervalSince(current.0) * decay) * -expm1(-seconds * decay)
            weightedRate += (current.1 - previous.1) / seconds * 3600 * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        let rate = weightedRate / totalWeight
        guard rate > 0, rate.isFinite else { return nil }
        let date = now.addingTimeInterval((100 - window.usedPercent) / rate * 3600)
        guard date < reset else { return nil }
        return UsageProjection(percentPerHour: rate, reachesLimitAt: date)
    }

    public static func events(snapshot: AccountSnapshot, accountName: String, history: [AccountSnapshot],
                              settings: MonitorSettings, sent: Set<String>, now: Date = Date()) -> [WarningEvent] {
        var result: [WarningEvent] = []
        func append(_ key: String, _ kind: WarningEvent.Kind, _ message: String, manual: Bool = false, legacyKey: String? = nil) {
            let id = stableID("\(snapshot.configurationID)|\(manual ? "manual" : snapshot.identity)|\(key)")
            guard !sent.contains(id) else { return }
            if let legacyKey, sent.contains(stableID("\(snapshot.configurationID)|\(snapshot.identity)|\(legacyKey)")) { return }
            result.append(WarningEvent(id: id, accountID: snapshot.configurationID, kind: kind,
                                       title: accountName, message: message, createdAt: now))
        }
        if snapshot.isFresh(at: now) {
            let previous = history.lazy.filter {
                $0.observedAt <= snapshot.observedAt && $0.configurationID == snapshot.configurationID && $0.identity == snapshot.identity
            }.max { $0.observedAt < $1.observedAt }
            let normalized = QuotaPeriod.normalizing(snapshot, previous: previous)
            for window in normalized.windows {
                guard window.hasValidUsage, window.resetsAt.map({ $0 > now }) ?? true else { continue }
                let key = QuotaPeriod.key(window: window, snapshot: snapshot)
                // Only migrate a minute-rounded warning when a prior poll proves it
                // belongs to this period. A nearby genuine reset must still warn.
                let legacyKey = window.legacyWarningPeriod.map { "\(window.id)|\($0)" }
                if settings.thresholdEnabled && window.usedPercent >= settings.threshold {
                    append("\(key)|threshold|\(settings.threshold)", .threshold,
                           tr("{0}: {1} % verbraucht.", window.title, QuotaNumbers.integerText(window.usedPercent)), legacyKey: legacyKey.map { "\($0)|threshold|\(settings.threshold)" })
                }
                if settings.paceEnabled, let ideal = window.idealPercent(at: now), ideal >= 5,
                   window.usedPercent > ideal + settings.paceBuffer {
                    append("\(key)|pace", .pace,
                           tr("{0}: {1} % verbraucht, gleichmäßig wären es {2} %.", window.title, QuotaNumbers.integerText(window.usedPercent), QuotaNumbers.integerText(ideal)), legacyKey: legacyKey.map { "\($0)|pace" })
                }
                if settings.forecastEnabled,
                   let forecast = projection(window: window, snapshot: snapshot, history: history, now: now),
                   forecast.reachesLimitAt.timeIntervalSince(now) <= settings.forecastHours * 3600 {
                    let remaining = durationText(forecast.reachesLimitAt.timeIntervalSince(now))
                    append("\(key)|forecast", .forecast, tr("{0}: Bei diesem Tempo voraussichtlich in {1} ausgeschöpft, vor dem Reset.", window.title, remaining), legacyKey: legacyKey.map { "\($0)|forecast" })
                }
            }
        }
        if settings.expiryEnabled {
            for benefit in snapshot.benefits where benefit.status == .available && benefit.count > 0 {
                guard benefit.isManual || (snapshot.benefitsChecked && snapshot.isFresh(at: now)),
                      let expiry = QuotaNumbers.date(benefit.expiresAt), expiry > now else { continue }
                let hours = expiry.timeIntervalSince(now) / 3600
                guard let stage = settings.expiryHours.filter({ $0 > 0 && hours <= $0 }).min() else { continue }
                let when = expiry.formatted(.dateTime.day().month().hour().minute().locale(Localization.locale))
                append("benefit|\(benefit.id)|\(expiry.timeIntervalSince1970)|\(stage)", .expiry,
                       tr("{0} · {1}: läuft am {2} ab.{3}", benefit.title, benefit.scope, when, benefit.isManual ? tr(" Manuell eingetragen.") : ""), manual: benefit.isManual)
            }
        }
        return result
    }
}
