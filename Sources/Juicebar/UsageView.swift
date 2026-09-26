import SwiftUI
import Charts
import JuicebarCore

struct UsageView: View {
    @ObservedObject var store: AppStore
    @State private var source: ActivitySource?
    @State private var days = 90
    @State private var metric: ActivityMetric = .cost
    @State private var showQuotas = false
    private var filtered: [ActivityDay] {
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: store.now))!
        return (store.activity?.days ?? []).filter { (source == nil || $0.source == source) && $0.day >= since }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: tr("Deine Nutzung."), subtitle: tr("Codex, Claude und OpenCode. Deine Aktivität auf diesem Mac und per SSH, gemeinsam im Verlauf."))
            HStack(spacing: 8) {
                sourceButton(nil, title: tr("Alle"))
                ForEach(ActivitySource.allCases) { item in sourceButton(item, title: item.name) }
                Spacer(minLength: 8)
                if store.localUsageLoading {
                    ProgressView().controlSize(.small)
                    Button(tr("Abbrechen")) { store.cancelActivityImport() }
                } else {
                    Button { store.loadLocalUsage() } label: { Label(tr("Aktualisieren"), systemImage: "arrow.clockwise") }.disabled(store.isDemo)
                }
            }
            if store.localUsageLoading { Text(store.activityProgress).font(.caption).foregroundStyle(.secondary) }
            if let error = store.localUsageError { Text(error).font(.callout).foregroundStyle(.orange) }
            if let report = store.activity {
                HStack {
                    Text(store.isPaused ? tr("Automatische Aktualisierung pausiert") : tr("Automatisch alle 5 Minuten · {0}", updatedText(report.observedAt, now: store.now)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    JuiceSegments(title: tr("Zeitraum"), selection: $days, options: [(tr("30 Tage"), 30), (tr("90 Tage"), 90)]).frame(width: 175)
                }
                summary
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tr("Aktivität")).font(.headline)
                                Text(tr("90 Tage · Antworten und archivierte Nachrichten")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(tr("{0} aktive Tage", Set(report.days.filter { source == nil || $0.source == source }.map(\.day)).count))
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                        }
                        ActivityCalendar(days: report.days.filter { source == nil || $0.source == source }, now: store.now)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text(tr("Im Tagesverlauf")).font(.headline)
                            Spacer()
                        }
                        HStack {
                            JuiceSegments(title: tr("Messgröße"), selection: $metric, options: ActivityMetric.allCases.map { (tr($0.rawValue), $0) }).frame(width: 330)
                            Spacer()
                        }
                        if filtered.isEmpty { EmptyState(symbol: "chart.bar", title: tr("Hier ist noch Ruhe."), message: tr("Für diese Auswahl sind keine lokalen Nutzungsdaten vorhanden.")) }
                        else {
                            Chart(filtered) { day in
                                BarMark(x: .value(tr("Tag"), day.day, unit: .day), y: .value(tr(metric.rawValue), metric.value(day)))
                                    .foregroundStyle(by: .value(tr("Werkzeug"), day.source.name))
                            }
                            .chartForegroundStyleScale(domain: ActivitySource.allCases.map(\.name), range: ActivitySource.allCases.map(activityColor))
                            .chartXScale(domain: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: store.now))!...store.now)
                            .chartYAxis {
                                AxisMarks(position: .leading) { value in
                                    AxisGridLine()
                                    AxisValueLabel { if let number = value.as(Double.self) { Text(compactNumber(number)) } }
                                }
                            }
                            .frame(height: 220)
                        }
                        Text(metric == .cost ? tr("API-Gegenwert in USD zu heutigen Standardpreisen. Unbepreiste Nutzung fehlt in diesen Balken.") : tr("Tokens einschließlich Cache. Wiederholte Modellantworten zählen einmal. Archivierte Nachrichten werden separat ausgewiesen."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source == nil {
                    HStack(spacing: 12) {
                        ForEach(ActivitySource.allCases) { item in
                            let values = filtered.filter { $0.source == item }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) { Circle().fill(activityColor(item)).frame(width: 6, height: 6); Text(item.name).font(.system(size: 12, weight: .semibold)) }
                                Text(costLabel(values)).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                                Text(tr("{0} Tokens · API-Gegenwert", compactNumber(values.reduce(0) { $0 + $1.tokens }))).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(activityColor(item).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Panel {
                    DisclosureGroup(report.warnings.isEmpty ? tr("Datenquellen & Preisberechnung") : tr("Datenquellen & Preisberechnung · {0} Hinweise", report.warnings.count)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("Logs dieses Macs und der eingerichteten SSH-Rechner, einschließlich Unteragenten. Keine verlässliche Zuordnung zu einzelnen Abos. Vor dem ersten Import gelöschte Logs und nicht verbundene Geräte können fehlen. Anbieter-Tageswerte werden nicht zusätzlich addiert."))
                            Text(tr("Stand: {0}. Automatischer Import beim Start und alle fünf Minuten. Unveränderte Dateien werden aus dem Cache gelesen. Bereits erfasste Nutzungsdaten bleiben 90 Tage erhalten, auch wenn ein Chat gelöscht wird.", report.observedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale))))
                            Text(tr("API-Gegenwert: aktuelle Standardpreise in USD, Stand {0}. Input, Output und Cache werden getrennt berechnet; lange Kontexte berücksichtigen modellabhängige Aufpreise. Ohne Steuern, Toolgebühren, Fast-Modus oder Batch-Rabatte. Keine Abo-Rechnung. Fehlt die Cache-Dauer, wird die kurze Dauer angenommen.", APICost.priceDate))
                            HStack {
                                Link(tr("OpenAI-Preise"), destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                                Link(tr("OpenCode-Preise"), destination: URL(string: "https://opencode.ai/docs/zen/")!)
                                Link(tr("Claude-Preise"), destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
                            }
                            ForEach(ModelAliases.entries, id: \.canonicalModel) { alias in
                                Link("\(alias.names[0]) → \(alias.displayName)", destination: alias.source)
                            }
                            Text(tr("Veröffentlichte Alpha-Modelle werden auch rückwirkend zum API-Gegenwert bewertet. Die kostenlose Testphase wird dadurch nicht nachträglich zur Rechnung."))
                            let missing = Set(filtered.flatMap { $0.unpricedModels }).sorted()
                            if !missing.isEmpty { Text(tr("Noch ohne Kostenbewertung: ") + missing.joined(separator: ", ")) }
                            ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(Palette.accent) }
                            ForEach(report.notices, id: \.self) { Text($0) }
                            Button(tr("Andere OpenCode-Datenbank …")) { store.selectLocalDatabase() }.disabled(store.isDemo || store.localUsageLoading)
                        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    }
                }
            } else if !store.localUsageLoading {
                Panel { EmptyState(symbol: "calendar", title: tr("Deine letzten 90 Tage."), message: tr("Deine Nutzungsdaten werden automatisch geladen. Der erste Import kann bei vielen Chats etwas dauern.")) }
            }
            if source == nil || source == .opencode, let local = store.localUsage, !local.models.isEmpty {
                Panel {
                    DisclosureGroup(tr("OpenCode auf diesem Mac · Modelle · 90 Tage")) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(local.models.prefix(15)) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let alias = ModelAliases.resolve(model: model.model, provider: model.provider) {
                                            Text(alias.displayName)
                                            Text(tr("Logname: {0} · {1}", model.model, model.provider)).font(.caption).foregroundStyle(.secondary)
                                        } else {
                                            Text(model.model); Text(model.provider).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(compactNumber(model.tokens)).monospacedDigit()
                                    Text(model.cost.formatted(.currency(code: "USD"))).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                }.font(.callout)
                                Divider()
                            }
                            Text(tr("Kosten sind OpenCode-Schätzungen, keine Abo-Rechnung. SSH-Nutzung ist in dieser lokalen Modellliste nicht enthalten.")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 14)
                    }
                }
            }
            SSHSourcesView(store: store)
            Panel {
                DisclosureGroup(tr("Kontingent-Messungen · letzte 24 Stunden"), isExpanded: $showQuotas) {
                    QuotaHistoryChart(store: store).padding(.top, 16)
                }
            }
            ForEach(store.accounts.filter { store.snapshots[$0.id]?.dailyUsage.contains { $0.cost != nil } == true }) { account in
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(tr("{0} · gemeldete Kosten in USD", account.displayName)).font(.headline)
                        Chart(store.snapshots[account.id]?.dailyUsage ?? []) { day in
                            BarMark(x: .value(tr("Tag"), day.day, unit: .day), y: .value("USD", day.cost ?? 0)).foregroundStyle(Palette.provider(account.provider))
                        }.frame(height: 150)
                    }
                }
            }
        }.onAppear { store.refreshActivityIfNeeded() }
    }
    private func costLabel(_ values: [ActivityDay]) -> String {
        guard values.contains(where: { $0.pricedTokens > 0 }) else { return "—" }
        return values.reduce(0) { $0 + $1.apiCost }.formatted(.currency(code: "USD"))
    }
    private var summary: some View {
        let tokens = filtered.reduce(0) { $0 + $1.tokens }
        let priced = filtered.reduce(0) { $0 + $1.pricedTokens }
        let archived = filtered.reduce(0) { $0 + $1.archivedMessages }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("THEORETISCHE API-KOSTEN · {0} TAGE", days)).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.accent)
                    Text(costLabel(filtered)).font(.system(size: 40, weight: .medium, design: .rounded)).tracking(-1.5).monospacedDigit()
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(compactNumber(tokens)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(tr("Tokens einschließlich Cache")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top) {
                Text(priced < tokens ? tr("Teilbetrag · {0} % der Tokens bepreist", Int(tokens > 0 ? 100 * priced / tokens : 0)) : tr("API-Gegenwert zu Standardpreisen · keine Abo-Rechnung"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(tr("{0} Modellantworten", filtered.reduce(0) { $0 + $1.responses }.formatted()) + (archived > 0 ? tr(" · {0} archivierte Nachrichten", archived.formatted()) : ""))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.font(.caption)
        }.padding(22).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
    private func sourceButton(_ item: ActivitySource?, title: String) -> some View {
        Button { source = item } label: { Text(title) }
            .buttonStyle(JuiceButtonStyle(prominent: source == item))
            .accessibilityAddTraits(source == item ? .isSelected : [])
    }
}

enum ActivityMetric: String, CaseIterable, Identifiable {
    case cost = "API-Kosten", tokens = "Tokens", responses = "Antworten"
    func value(_ day: ActivityDay) -> Double {
        switch self { case .cost: day.apiCost; case .tokens: day.tokens; case .responses: Double(day.responses) }
    }
    var id: String { rawValue }
}
func activityColor(_ source: ActivitySource) -> Color {
    Palette.provider(source == .codex ? .codex : source == .claude ? .claude : .opencodeGo)
}
func compactNumber(_ number: Double) -> String { number.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }

struct ActivityCalendar: View {
    let days: [ActivityDay]
    let now: Date
    @State private var selected: Date?
    private var calendar: Calendar { var value = Calendar.current; value.firstWeekday = 2; return value }
    private var start: Date {
        let first = calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))!
        return calendar.dateInterval(of: .weekOfYear, for: first)!.start
    }
    private var cells: [Date] {
        let count = calendar.dateComponents([.day], from: start, to: now).day! + 1
        return (0..<(Int(ceil(Double(count) / 7)) * 7)).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
    private var totals: [Date: Int] { Dictionary(grouping: days, by: \.day).mapValues { $0.reduce(0) { $0 + $1.responses + $1.archivedMessages } } }
    var body: some View {
        let dates = cells, counts = totals, maximum = max(1, counts.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 5) {
                VStack(spacing: 5) {
                    Text(" ").frame(height: 16)
                    ForEach(0..<7) { row in Text(row == 0 ? tr("Mo") : row == 2 ? tr("Mi") : row == 4 ? tr("Fr") : " ").font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 21) }
                }.frame(width: 18)
                ForEach(0..<(dates.count / 7), id: \.self) { week in
                    let first = dates[week * 7]
                    VStack(spacing: 5) {
                        Text(week == 0 || calendar.component(.day, from: first) <= 7 ? first.formatted(.dateTime.month(.abbreviated)) : " ")
                            .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 16)
                        ForEach(0..<7) { row in
                            let date = dates[week * 7 + row], count = counts[date] ?? 0
                            let valid = date <= now && date >= calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))!
                            Button { selected = date } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(valid ? color(count, maximum: maximum) : Color.clear)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected == date ? Palette.accent : Color.primary.opacity(valid ? 0.06 : 0), lineWidth: selected == date ? 2 : 1))
                                    .frame(height: 21)
                            }.buttonStyle(.plain).disabled(!valid)
                                .help(detail(date)).accessibilityLabel(detail(date))
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 4) {
                Text(selected.map(detail) ?? tr("Ein Tag, alle Werkzeuge. Klicke für die Aufschlüsselung."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(tr("Wenig")).font(.system(size: 9)).foregroundStyle(.secondary)
                ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(index == 0 ? Color.primary.opacity(0.05) : Palette.green.opacity(Double(index) / 4)).frame(width: 9, height: 9) }
                Text(tr("Viel")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func color(_ count: Int, maximum: Int) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.05) }
        let level = max(1, ceil(4 * log1p(Double(count)) / log1p(Double(maximum))))
        return Palette.green.opacity(level / 4)
    }
    private func detail(_ date: Date) -> String {
        let values = days.filter { calendar.isDate($0.day, inSameDayAs: date) }
        let total = values.reduce(0) { $0 + $1.responses }
        let archived = values.reduce(0) { $0 + $1.archivedMessages }
        let breakdown = values.map { "\($0.source.name) \($0.responses)" }.joined(separator: " · ")
        if archived > 0 { return tr("{0}: {1} archivierte Claude-Nachrichten", date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale)), archived) + (total > 0 ? tr(" · {0} Modellantworten anderer Werkzeuge", total) : "") + tr(" · Claude-Kosten nicht rekonstruierbar") }
        return tr("{0}: {1} Antworten{2}", date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale)), total, breakdown.isEmpty ? tr(" · keine protokollierte Aktivität") : " · \(breakdown)")
    }
}

struct QuotaHistoryChart: View {
    @ObservedObject var store: AppStore
    private var points: [QuotaPoint] {
        store.accounts.filter(\.enabled).flatMap { account in
            (store.history[account.id] ?? []).filter { $0.observedAt > store.now.addingTimeInterval(-86400) }.flatMap { snapshot in
                QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider).map { window in QuotaPoint(date: snapshot.observedAt, value: store.settings.displayMode.value(used: window.usedPercent), label: "\(account.displayName) · \(window.title)", series: "\(account.id)|\(snapshot.identity)|\(window.id)|\(window.resetsAt?.timeIntervalSince1970 ?? 0)") }
            }
        }
    }
    var body: some View {
        let values = points
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Direkte Messwerte der Anbieter seit dem ersten Juicebars-Start. Eine waagerechte Linie bedeutet, dass sich der gemeldete Stand nicht verändert hat. Abo-Prozente lassen sich nicht aus Log-Tokens rekonstruieren.")).font(.caption).foregroundStyle(.secondary)
            if values.count < 2 { Text(tr("Nach weiteren Abfragen erscheint hier der Verlauf.")).foregroundStyle(.secondary) }
            else {
                Chart(Array(values.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(tr("Zeit"), point.date), y: .value(store.settings.displayMode.label, point.value), series: .value(tr("Fenster"), point.series))
                        .interpolationMethod(.stepEnd).foregroundStyle(by: .value(tr("Kontingent"), point.label))
                }.chartYScale(domain: 0...100).chartYAxisLabel(tr("{0} in %", store.settings.displayMode.label)).frame(height: 210)
            }
        }
    }
}
private struct QuotaPoint { var date: Date; var value: Double; var label: String; var series: String }
