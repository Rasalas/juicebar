import SwiftUI
import Charts
import JuicebarCore

/// Mouse inspection stays selected when the pointer leaves. Keyboard focus never follows hover.
private struct ChartDateOverlay: View {
    let proxy: ChartProxy
    let select: (Date) -> Void
    let focus: () -> Void
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case let .active(location) = phase { inspect(location, in: geometry) }
                }
                .gesture(SpatialTapGesture().onEnded { event in
                    focus(); inspect(event.location, in: geometry)
                })
                .accessibilityHidden(true)
        }
    }
    private func inspect(_ location: CGPoint, in geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let plot = geometry[anchor]
        guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else { return }
        select(date)
    }
}

struct ActivityDailyChart: View {
    let days: [ActivityDay]
    let dates: [Date]
    let metric: ActivityMetric
    @Binding var selection: Date?
    @FocusState private var focused: Bool
    private var selected: Date? { UsageSelection.nearest(selection, in: dates) }
    var body: some View {
        let sources = ActivitySource.allCases.filter { source in days.contains { $0.source == source } }
        let totals = Dictionary(grouping: days, by: \.day).values.map { $0.reduce(0) { $0 + (metric.plottedValue($1) ?? 0) } }
        return VStack(alignment: .leading, spacing: 12) {
            if days.isEmpty {
                Text(tr("Für diese Auswahl sind keine lokalen Nutzungsdaten vorhanden.")).foregroundStyle(.secondary)
            } else {
                if !days.contains(where: { metric.plottedValue($0) != nil }) {
                    Text(tr("Für diese Messgröße sind keine Werte bekannt.")).font(.caption).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(days) { day in
                        if let value = metric.plottedValue(day) {
                            BarMark(x: .value(tr("Tag"), day.day, unit: .day), y: .value(tr(metric.rawValue), value))
                                .foregroundStyle(by: .value(tr("Werkzeug"), day.source.name))
                            if value == 0 {
                                PointMark(x: .value(tr("Tag"), day.day, unit: .day), y: .value(tr(metric.rawValue), value))
                                    .foregroundStyle(by: .value(tr("Werkzeug"), day.source.name)).symbolSize(30)
                            }
                        }
                    }
                    if let selected {
                        RuleMark(x: .value(tr("Ausgewählter Tag"), Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: selected) ?? selected))
                            .foregroundStyle(Palette.accent).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .accessibilityHidden(true)
                    }
                }
                .chartForegroundStyleScale(domain: sources.map(\.name), range: sources.map(activityColor))
                .chartYScale(domain: 0...max(1, totals.max() ?? 0))
                .chartXScale(domain: (dates.first ?? Date())...(Calendar.current.date(byAdding: .day, value: 1, to: dates.last ?? Date())!))
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text(compactNumber(number)) } }
                    }
                }
                .chartOverlay { proxy in
                    ChartDateOverlay(proxy: proxy, select: { date in
                        selection = UsageSelection.nearest(Calendar.current.startOfDay(for: date), in: dates)
                    }, focus: { focused = true })
                }
                .frame(height: 220)
                .focusable().focused($focused).focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accent : .clear, lineWidth: 2).padding(-4))
                .onMoveCommand { direction in
                    switch direction {
                    case .left, .down: move(-1)
                    case .right, .up: move(1)
                    @unknown default: break
                    }
                }
                .accessibilityLabel(tr("Im Tagesverlauf") + " · " + tr(metric.rawValue))
                .accessibilityValue(detail)
                .accessibilityHint(tr("Mit den Pfeiltasten einen Tag wählen."))
                .accessibilityAdjustableAction { move($0 == .increment ? 1 : -1) }
                .accessibilityChartDescriptor(DailyChartDescriptor(days: days, metric: metric))
            }
            ActivityDayDetail(date: selected, days: days, metric: metric)
        }
    }
    private var detail: String {
        guard let selected else { return tr("Keine protokollierte Aktivität") }
        return ActivityDayDetail.label(date: selected, days: days, metric: metric)
    }
    private func move(_ offset: Int) { selection = UsageSelection.move(selected, by: offset, in: dates) }
}

struct ActivityDayDetail: View {
    let date: Date?
    let days: [ActivityDay]
    let metric: ActivityMetric
    var body: some View {
        if let date {
            let values = Self.values(date: date, days: days)
            VStack(alignment: .leading, spacing: 5) {
                Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale))).fontWeight(.medium)
                Text(ActivityMetricDetails(values).label(metric))
                if Set(values.map(\.source)).count > 1 {
                    ForEach(ActivitySource.allCases.filter { source in values.contains { $0.source == source } }) { source in
                        Text(source.name + ": " + ActivityMetricDetails(values.filter { $0.source == source }).label(metric))
                    }
                }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }
    static func values(date: Date, days: [ActivityDay]) -> [ActivityDay] {
        days.filter { Calendar.current.isDate($0.day, inSameDayAs: date) }
    }
    static func label(date: Date, days: [ActivityDay], metric: ActivityMetric) -> String {
        let values = values(date: date, days: days)
        let total = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale)) + ": " + ActivityMetricDetails(values).label(metric)
        let sources = ActivitySource.allCases.filter { source in values.contains { $0.source == source } }
        return total + (sources.count > 1 ? ". " + sources.map { source in
            source.name + ": " + ActivityMetricDetails(values.filter { $0.source == source }).label(metric)
        }.joined(separator: ". ") : "")
    }
}

private struct DailyChartDescriptor: AXChartDescriptorRepresentable {
    let days: [ActivityDay]
    let metric: ActivityMetric
    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = Array(Set(days.map(\.day))).sorted()
        let names = dates.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale)) }
        let x = AXCategoricalDataAxisDescriptor(title: tr("Tag"), categoryOrder: names)
        let totals = Dictionary(grouping: days, by: \.day).values.map { $0.reduce(0) { $0 + (metric.plottedValue($1) ?? 0) } }
        let y = AXNumericDataAxisDescriptor(title: tr(metric.rawValue), range: 0...max(1, totals.max() ?? 0), gridlinePositions: []) { value in
            value.formatted(.number.precision(.fractionLength(0...6)).locale(Localization.locale))
        }
        let series = ActivitySource.allCases.compactMap { source -> AXDataSeriesDescriptor? in
            let values = days.filter { $0.source == source }
            guard !values.isEmpty else { return nil }
            return AXDataSeriesDescriptor(name: source.name, isContinuous: false, dataPoints: values.compactMap { day in
                guard let value = metric.plottedValue(day), let index = dates.firstIndex(of: day.day) else { return nil }
                return AXDataPoint(x: names[index], y: value, label: ActivityMetricDetails([day]).label(metric))
            })
        }
        return AXChartDescriptor(title: tr("Im Tagesverlauf"), summary: tr("Unbekannte Werte fehlen im Diagramm."), xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

struct QuotaTimelineChart: View {
    let points: [QuotaPoint]
    let displayLabel: String
    @State var selection: QuotaPoint.ID?
    @FocusState private var focused: Bool
    private var selected: QuotaPoint? { QuotaSelection.resolve(selection, in: points) }
    private var series: [String] { Array(Set(points.map(\.series))).sorted() }
    var body: some View {
        let counts = Dictionary(grouping: points, by: \.series).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty {
                Text(tr("Nach weiteren Abfragen erscheint hier der Verlauf.")).foregroundStyle(.secondary)
            } else {
                if series.count > 1 {
                    Picker(tr("Kontingent"), selection: Binding(get: { selected?.series ?? "" }, set: { series in
                        selection = QuotaSelection.resolve(.init(series: series, date: selected?.date ?? Date()), in: points)?.id
                    })) {
                        ForEach(series, id: \.self) { id in Text(seriesLabel(id)).tag(id) }
                    }.pickerStyle(.menu)
                }
                Chart(points) { point in
                    LineMark(x: .value(tr("Zeit"), point.date), y: .value(displayLabel, min(point.value, 100)), series: .value(tr("Fenster"), point.series))
                        .interpolationMethod(.stepEnd).foregroundStyle(by: .value(tr("Kontingent"), point.label))
                    if point.id == selected?.id || counts[point.series] == 1 {
                        PointMark(x: .value(tr("Zeit"), point.date), y: .value(displayLabel, min(point.value, 100)))
                            .foregroundStyle(by: .value(tr("Kontingent"), point.label))
                            .symbolSize(point.id == selected?.id ? 70 : 30)
                    }
                }
                .chartXScale(domain: timeRange)
                .chartYScale(domain: 0...100).chartYAxisLabel(tr("{0} in %", displayLabel))
                .chartOverlay { proxy in
                    ChartDateOverlay(proxy: proxy, select: { date in
                        guard let series = selected?.series else { return }
                        selection = QuotaSelection.resolve(.init(series: series, date: date), in: points)?.id
                    }, focus: { focused = true })
                }
                .frame(height: 210)
                .focusable().focused($focused).focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accent : .clear, lineWidth: 2).padding(-4))
                .onMoveCommand { direction in
                    switch direction {
                    case .left: move(-1)
                    case .right: move(1)
                    case .up: selection = QuotaSelection.changeSeries(selection, by: -1, in: points)
                    case .down: selection = QuotaSelection.changeSeries(selection, by: 1, in: points)
                    @unknown default: break
                    }
                }
                .accessibilityLabel(tr("Kontingent-Messungen · letzte 24 Stunden"))
                .accessibilityValue(selected.map { QuotaSelection.detail($0, displayLabel: displayLabel) } ?? "")
                .accessibilityHint(tr("Links und rechts: Messung. Oben und unten: Kontingent. Maus: gewähltes Kontingent prüfen."))
                .accessibilityAdjustableAction { move($0 == .increment ? 1 : -1) }
                if let selected {
                    Text(QuotaSelection.detail(selected, displayLabel: displayLabel))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(tr("Links und rechts: Messung. Oben und unten: Kontingent. Maus: gewähltes Kontingent prüfen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: points.map(\.id), initial: true) { _, _ in selection = selected?.id }
    }
    private func move(_ offset: Int) { selection = QuotaSelection.move(selection, by: offset, in: points) }
    private var timeRange: ClosedRange<Date> {
        let first = points.map(\.date).min() ?? Date(), last = points.map(\.date).max() ?? Date()
        let padding = max(60, last.timeIntervalSince(first) * 0.02)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }
    private func seriesLabel(_ id: String) -> String {
        guard let point = points.first(where: { $0.series == id }) else { return id }
        let duplicates = Set(points.filter { $0.label == point.label }.map(\.series)).count > 1
        guard duplicates, let start = points.filter({ $0.series == id }).map(\.date).min() else { return point.label }
        return point.label + " · " + start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale))
    }
}
