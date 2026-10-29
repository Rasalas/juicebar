import SwiftUI
import Charts
import JuicebarCore

struct UsageView: View {
    let store: AppStore
    @State private var source: ActivitySource?
    @State private var days = 90
    @State private var metric: ActivityMetric = .cost
    @State private var showQuotas = false
    @State private var selectedDay: Date?
    private var filtered: [ActivityDay] {
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: store.now))!
        return (store.activity?.days ?? []).filter { (source == nil || $0.source == source) && $0.day >= since && $0.day <= store.now }
    }
    var body: some View {
        let filtered = self.filtered
        return VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: tr("Deine Nutzung."), subtitle: tr("Deine Coding-Werkzeuge auf diesem Mac und per SSH, gemeinsam im Verlauf."))
            HStack(spacing: 8) {
                Picker(tr("Werkzeug"), selection: $source) {
                    Text(tr("Alle")).tag(ActivitySource?.none)
                    ForEach(ActivitySource.allCases) { item in Text(item.name).tag(Optional(item)) }
                }.pickerStyle(.menu).frame(width: 250)
                Spacer(minLength: 8)
                if store.localUsageLoading {
                    ProgressView().controlSize(.small)
                    Button(tr("Abbrechen")) { store.cancelActivityImport() }
                } else {
                    Button { store.loadLocalUsage() } label: { Label(tr("Aktualisieren"), systemImage: "arrow.clockwise") }.disabled(store.isDemo)
                }
            }
            if store.localUsageLoading { Text(store.activityProgress).font(.caption).foregroundStyle(.secondary) }
            if let error = store.localUsageError { Text(error).font(.callout).foregroundStyle(Palette.warning) }
            if let report = store.activity {
                HStack {
                    Text(store.isPaused ? tr("Automatische Aktualisierung pausiert") : tr("Automatisch alle 5 Minuten · Zusammenstellung: {0}", report.observedAt.formatted(.dateTime.hour().minute().locale(Localization.locale))))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    JuiceSegments(title: tr("Zeitraum"), selection: $days, options: [(tr("30 Tage"), 30), (tr("90 Tage"), 90)]).frame(width: 175)
                }
                UsageFreshnessView(report: report, source: source)
                summary(filtered)
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tr("Aktivität")).font(.headline)
                                Text(tr("{0} Tage · {1}", days, tr(metric.rawValue))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(tr("{0} aktive Tage", Set(filtered.map(\.day)).count))
                                .font(.callout.weight(.medium)).foregroundStyle(Palette.accent)
                        }
                        ActivityCalendar(days: filtered, now: store.now, numberOfDays: days, metric: metric, selection: $selectedDay)
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
                        ActivityDailyChart(days: filtered, dates: UsageSelection.days(ending: store.now, count: days), metric: metric, selection: $selectedDay)
                        Text(metric == .cost ? tr("API-Gegenwert in USD. Protokollierte Kostenschätzungen haben Vorrang, sonst gelten heutige Standardpreise. Unbepreiste Nutzung fehlt in diesen Balken.") : tr("Tokens einschließlich Cache. Wiederholte Modellantworten zählen einmal. Archivierte Nachrichten werden separat ausgewiesen."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source == nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(ActivitySource.allCases.filter { item in filtered.contains { $0.source == item } }) { item in
                            let values = filtered.filter { $0.source == item }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) { Circle().fill(activityColor(item)).frame(width: 6, height: 6); Text(item.name).font(.callout.weight(.semibold)) }
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
                            Text(tr("Zusammenstellung: {0}. Quellen können ältere Werte enthalten. Automatischer Import beim Start und alle fünf Minuten. Unveränderte Dateien werden aus dem Cache gelesen. Bereits erfasste Nutzungsdaten bleiben 90 Tage erhalten, auch wenn ein Chat gelöscht wird.", report.observedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale))))
                            Text(tr("API-Gegenwert: aktuelle Standardpreise in USD, Stand {0}. Input, Output und Cache werden getrennt berechnet; lange Kontexte berücksichtigen modellabhängige Aufpreise. Ohne Steuern, Toolgebühren, Fast-Modus oder Batch-Rabatte. Keine Abo-Rechnung. Fehlt die Cache-Dauer, wird die kurze Dauer angenommen.", report.pricingVerifiedOn ?? tr("Unbekannt")))
                            Text(tr("Pi, Cline, Roo Code und Kilo: Kosten aus dem Log haben Vorrang. Fehlen sie, verwenden wir den Preiskatalog. Roo protokolliert dabei keinen Modellnamen. Auch bei Abo-Anbietern ist dies ein API-Gegenwert, keine Rechnung. Pi-Tool-Verbrauch und Cache-Warming erhöhen die Tokenzahl, nicht die Anzahl der Antworten."))
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
                            ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(Palette.warning) }
                            ForEach(report.sources?.filter { $0.issue != nil } ?? []) { item in
                                Text("\(item.label): \(item.issue ?? "")").foregroundStyle(Palette.warning)
                            }
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
                                    Text(model.costLabel).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                                }.font(.callout)
                                Divider()
                            }
                            Text(tr("Kosten sind OpenCode-Schätzungen, keine Abo-Rechnung. SSH-Nutzung ist in dieser lokalen Modellliste nicht enthalten.")).font(.caption).foregroundStyle(.secondary)
                            Text(tr("≥ zeigt nur den bepreisten Anteil. Fehlende Kosten sind nicht null.")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 14)
                    }
                }
            }
            ActivitySourcesView(store: store)
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
                        }.frame(height: 150).accessibilityLabel(tr("{0} · gemeldete Kosten in USD", account.displayName))
                    }
                }
            }
        }.onAppear { store.refreshActivityIfNeeded() }
            .onChange(of: UsageSelection.days(ending: store.now, count: days), initial: true) { _, dates in
                selectedDay = UsageSelection.nearest(selectedDay, in: dates)
            }
    }
    private func costLabel(_ values: [ActivityDay]) -> String {
        ActivityMetricDetails(values).costLabel()
    }

    private func summary(_ filtered: [ActivityDay]) -> some View {
        let tokens = filtered.reduce(0) { $0 + $1.tokens }
        let archived = filtered.reduce(0) { $0 + $1.archivedMessages }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("THEORETISCHE API-KOSTEN · {0} TAGE", days)).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.accent)
                    Text(costLabel(filtered)).font(.system(size: 34, weight: .medium, design: .rounded)).tracking(-1.2).monospacedDigit()
                    Label(tr("Keine Rechnung: so viel hätte diese Nutzung zu API-Preisen gekostet."), systemImage: "info.circle")
                        .font(.callout.weight(.medium))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(compactNumber(tokens)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(tr("Tokens einschließlich Cache")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top) {
                Text(ActivityMetricDetails(filtered).tokenCoverage).foregroundStyle(.secondary)
                Spacer()
                Text(tr("{0} Modellantworten", filtered.reduce(0) { $0 + $1.responses }.formatted(.number.locale(Localization.locale)))
                     + (archived > 0 ? tr(" · {0} archivierte Nachrichten", archived.formatted(.number.locale(Localization.locale))) : ""))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.font(.caption)
        }.padding(22).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }
}

func activityColor(_ source: ActivitySource) -> Color {
    switch source {
    case .codex: Palette.provider(.codex)
    case .claude: Palette.provider(.claude)
    case .opencode: Palette.provider(.opencodeGo)
    case .pi: Color(red: 0.55, green: 0.42, blue: 0.77)
    case .gemini: Color(red: 0.15, green: 0.63, blue: 0.67)
    case .cline: Color(red: 0.72, green: 0.48, blue: 0.15)
    case .roo: Color(red: 0.64, green: 0.40, blue: 0.35)
    case .kilo: Color(red: 0.54, green: 0.59, blue: 0.16)
    case .qwen: Color(red: 0.75, green: 0.38, blue: 0.62)
    }
}
func compactNumber(_ number: Double) -> String { number.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Localization.locale)) }

struct QuotaHistoryChart: View {
    let store: AppStore
    private var points: [QuotaPoint] {
        let since = store.now.addingTimeInterval(-86400)
        return store.accounts.filter(\.enabled).flatMap { account in
            var values: [QuotaPoint] = []
            for snapshot in store.quotaHistory(for: account.id).reversed().prefix(while: { $0.observedAt > since }).reversed() {
                values += QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider).filter(\.hasValidUsage).map { window in
                    QuotaPoint(date: snapshot.observedAt, value: store.settings.displayMode.value(used: window.usedPercent),
                               label: "\(account.displayName) · \(window.title)",
                               series: "\(account.id)|\(QuotaPeriod.key(window: window, snapshot: snapshot))")
                }
            }
            return values
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Direkte Messwerte der Anbieter seit dem ersten Juicebars-Start. Eine waagerechte Linie bedeutet, dass sich der gemeldete Stand nicht verändert hat. Abo-Prozente lassen sich nicht aus Log-Tokens rekonstruieren.")).font(.caption).foregroundStyle(.secondary)
            QuotaTimelineChart(points: points, displayLabel: store.settings.displayMode.label)
        }
    }
}
