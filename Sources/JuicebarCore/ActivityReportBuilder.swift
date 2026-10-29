import Foundation

extension ActivityReport {
    /// Folds events into a report while they are read. Keeps one compact record per (source, ID) instead of the events,
    /// so an import never holds its whole event list. Adding events in the order of a list gives that list's report.
    struct Builder {
        private typealias Digest = (UInt64, UInt64, UInt64, UInt64)
        private struct Text: Hashable { var id: String; var source: ActivitySource }
        /// The winning event of its key, reduced to what `preferred` and the aggregation read.
        private struct Record {
            var digest: Digest
            var date: Double
            var tokens: Double
            var cost: Double
            var session: Double
            var responses: Int
            var label: UInt32
            var source: ActivitySource
            var flags: UInt8
            var completeness: UInt8
            var preference: ActivityEvent.Preference {
                .init(tokens: tokens, completeness: completeness, session: flags & Builder.hasSession != 0 ? Date(timeIntervalSinceReferenceDate: session) : nil)
            }
        }
        private struct ModelKey: Hashable { var model: String; var provider: String }
        private struct Model { var key: ModelKey; var rate: CatalogDocument.Rate?; var alias: String?; var completeness: UInt8 }
        private static let priced: UInt8 = 2, hasSession: UInt8 = 4, textID: UInt8 = 8
        private static let chunkSize = 16384
        private let now: Date, calendar: Calendar, catalog = ModelCatalog.shared.snapshot
        // Fixed-size chunks and a slot table of record numbers: growing never copies the records,
        // which would double the peak, and the SHA-256 digest needs no further hashing.
        private var chunks: [[Record]] = [], count = 0
        private var slots = [UInt32](repeating: 0, count: 1024)
        private var texts: [Text: Int] = [:]
        private var modelIDs: [ModelKey: UInt32] = [:], models: [Model] = []

        init(now: Date, calendar: Calendar = .current) { self.now = now; self.calendar = calendar }

        mutating func add(_ event: ActivityEvent) {
            guard event.date <= now, event.tokens.isFinite, event.tokens > 0 else { return }
            let label = label(for: event)
            let preference = event.preference(labelCompleteness: models[Int(label)].completeness)
            let digest = CompactEvents.digest(event.id), text = digest == nil ? Text(id: event.id, source: event.source) : nil
            var slot = 0
            let existing: Int?
            if let digest { (slot, existing) = find(digest, source: event.source) } else { existing = texts[text!] }
            // Streaming blocks may repeat a message with an updated output count.
            if let existing {
                let record = chunks[existing / Self.chunkSize][existing % Self.chunkSize]
                guard !ActivityEvent.keepsFirst(source: event.source, record.preference, preference) else { return }
                chunks[existing / Self.chunkSize][existing % Self.chunkSize] = self.record(event, digest: digest, label: label, preference: preference)
                return
            }
            if count % Self.chunkSize == 0 { chunks.append([]); chunks[chunks.count - 1].reserveCapacity(Self.chunkSize) }
            chunks[chunks.count - 1].append(record(event, digest: digest, label: label, preference: preference))
            count += 1
            if let text { texts[text] = count - 1; return }
            slots[slot] = UInt32(count)
            if count * 2 > slots.count { grow() }
        }

        /// The slot holding the digest's record, or the empty slot where it belongs.
        private func find(_ digest: Digest, source: ActivitySource) -> (slot: Int, index: Int?) {
            let mask = slots.count - 1
            var slot = Int(truncatingIfNeeded: digest.0) & mask
            while slots[slot] != 0 {
                let index = Int(slots[slot]) - 1, record = chunks[index / Self.chunkSize][index % Self.chunkSize]
                if record.flags & Self.textID == 0, record.source == source, record.digest == digest { return (slot, index) }
                slot = (slot + 1) & mask
            }
            return (slot, nil)
        }

        private mutating func grow() {
            slots = [UInt32](repeating: 0, count: slots.count * 2)
            for (chunkIndex, chunk) in chunks.enumerated() {
                for (offset, record) in chunk.enumerated() where record.flags & Self.textID == 0 {
                    slots[find(record.digest, source: record.source).slot] = UInt32(chunkIndex * Self.chunkSize + offset + 1)
                }
            }
        }

        private mutating func label(for event: ActivityEvent) -> UInt32 {
            let key = ModelKey(model: event.model, provider: event.provider)
            if let id = modelIDs[key] { return id }
            let alias = catalog.resolve(model: event.model, provider: event.provider)
            let label = UInt32(models.count); modelIDs[key] = label
            models.append(Model(key: key, rate: APICost.rate(model: event.model, provider: event.provider, catalog: catalog),
                                alias: alias.map { "\(event.model) → \($0.displayName)" },
                                completeness: ActivityEvent.labelCompleteness(model: event.model, provider: event.provider)))
            return label
        }

        private func record(_ event: ActivityEvent, digest: Digest?, label: UInt32, preference: ActivityEvent.Preference) -> Record {
            var flags: UInt8 = digest == nil ? Self.textID : 0, cost = 0.0
            if let reported = event.reportedCost, reported.isFinite, reported >= 0 {
                cost = reported; flags |= Self.priced
            } else if let usage = event.usage, abs(usage.total - event.tokens) < 0.5, let rate = models[Int(label)].rate,
                      let estimate = APICost.estimate(rate: rate, usage: usage) {
                cost = estimate; flags |= Self.priced
            }
            if event.sessionStartedAt != nil { flags |= Self.hasSession }
            return Record(digest: digest ?? (0, 0, 0, 0), date: event.date.timeIntervalSinceReferenceDate, tokens: event.tokens, cost: cost,
                          session: event.sessionStartedAt?.timeIntervalSinceReferenceDate ?? 0, responses: event.responseCount ?? 1,
                          label: label, source: event.source, flags: flags, completeness: preference.completeness)
        }

        func report(notices: [String] = [], warnings: [String] = []) -> ActivityReport {
            struct DayKey: Hashable { var source: ActivitySource; var day: Date }
            var groups: [DayKey: ActivityDay] = [:], hourMasks: [DayKey: Int] = [:], used = [Bool](repeating: false, count: models.count)
            let hoursSince = now.addingTimeInterval(-Double(ActivityReport.hourHistoryDays) * 86400)
            // UTC buckets only index calendar-derived intervals. The intervals decide
            // membership, including local midnight, short/long DST days, and date skips.
            var dayIntervals: [Double: [DateInterval]] = [:]
            func startOfDay(_ date: Date) -> Date {
                let bucket = floor(date.timeIntervalSince1970 / 86400)
                let intervals = dayIntervals[bucket] ?? []
                if let interval = intervals.first(where: { date >= $0.start && date < $0.end }) { return interval.start }
                guard let interval = calendar.dateInterval(of: .day, for: date) else { return calendar.startOfDay(for: date) }
                if intervals.count < 4 && (dayIntervals.count < 256 || dayIntervals[bucket] != nil) {
                    dayIntervals[bucket] = intervals + [interval]
                }
                return interval.start
            }
            for chunk in chunks {
                for record in chunk {
                    used[Int(record.label)] = true
                    let date = Date(timeIntervalSinceReferenceDate: record.date), day = startOfDay(date)
                    let key = DayKey(source: record.source, day: day)
                    var value = groups[key] ?? ActivityDay(day: day, source: record.source, tokens: 0, responses: 0)
                    value.tokens += record.tokens; value.responses += record.responses
                    if record.flags & Self.priced != 0 { value.apiCost += record.cost; value.pricedTokens += record.tokens }
                    else { value.unpricedModels.insert(models[Int(record.label)].key.model) }
                    groups[key] = value
                    if date >= hoursSince {
                        // Offset from the day start; on DST change days this shifts by one hour.
                        let hour = min(23, max(0, Int(date.timeIntervalSince(day) / 3600)))
                        hourMasks[key, default: 0] |= 1 << hour
                    }
                }
            }
            let days = groups.values.sorted { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
            let activeHours: [ActivityHours] = hourMasks.map { ActivityHours(day: $0.key.day, source: $0.key.source, hours: $0.value) }
                .sorted { $0.day == $1.day ? $0.source.rawValue < $1.source.rawValue : $0.day < $1.day }
            let resolved = Set(models.indices.filter { used[$0] }.compactMap { models[$0].alias }).sorted()
            let aliases: [String] = resolved.isEmpty ? [] : [tr("Veröffentlichte Modell-Aliase: ") + resolved.joined(separator: "; ") + tr(". Auch ältere Nutzung wird zum aktuellen API-Gegenwert bewertet; die damals kostenlose Preview bleibt in gemeldeten Kosten unverändert.")]
            return ActivityReport(days: days, activeHours: activeHours, notices: notices + aliases, warnings: warnings, observedAt: now)
        }
    }
}
