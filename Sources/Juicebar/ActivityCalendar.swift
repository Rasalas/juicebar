import SwiftUI
import JuicebarCore

struct ActivityCalendar: View {
    let days: [ActivityDay]
    let now: Date
    let numberOfDays: Int
    let metric: ActivityMetric
    @Binding var selection: Date?
    private let groupedDays: [Date: [ActivityDay]]
    private let calendar: Calendar
    private let firstDay: Date
    private let cells: [Date]
    private let labels: [Date: String]
    init(days: [ActivityDay], now: Date, numberOfDays: Int = 90, metric: ActivityMetric = .responses, selection: Binding<Date?> = .constant(nil)) {
        self.metric = metric
        _selection = selection
        self.days = days
        self.now = now
        self.numberOfDays = numberOfDays
        var calendar = Calendar.current; calendar.firstWeekday = 2
        self.calendar = calendar
        let grouped = Dictionary(grouping: days) { calendar.startOfDay(for: $0.day) }
        groupedDays = grouped
        firstDay = calendar.date(byAdding: .day, value: -(numberOfDays - 1), to: calendar.startOfDay(for: now))!
        let start = calendar.dateInterval(of: .weekOfYear, for: firstDay)!.start
        let count = calendar.dateComponents([.day], from: start, to: now).day! + 1
        let cells = (0..<(Int(ceil(Double(count) / 7)) * 7)).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        self.cells = cells
        labels = Dictionary(uniqueKeysWithValues: cells.map { ($0, ActivityDayDetail.label(date: $0, days: grouped[calendar.startOfDay(for: $0)] ?? [], metric: metric)) })
    }
    private var validDates: [Date] { cells.filter { $0 >= firstDay && $0 <= calendar.startOfDay(for: now) } }
    private var selected: Date? { UsageSelection.nearest(selection, in: validDates) }
    @FocusState private var focused: Bool
    private var totals: [Date: Double] { groupedDays.mapValues { $0.reduce(0) { $0 + (metric.plottedValue($1) ?? 0) } } }
    var body: some View {
        let dates = cells, counts = totals
        let maximum = counts.values.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(" ").frame(height: 16)
                    ForEach(0..<7) { row in Text(row == 0 ? tr("Mo") : row == 2 ? tr("Mi") : row == 4 ? tr("Fr") : " ").font(.caption2).foregroundStyle(.secondary).frame(height: 21) }
                }.fixedSize()
                ForEach(0..<(dates.count / 7), id: \.self) { week in
                    let first = dates[week * 7]
                    VStack(spacing: 5) {
                        Text(week == 0 || calendar.component(.day, from: first) <= 7 ? first.formatted(.dateTime.month(.abbreviated).locale(Localization.locale)) : " ")
                            .font(.caption2).foregroundStyle(.secondary).frame(height: 16)
                        ForEach(0..<7) { row in
                            let date = dates[week * 7 + row], count = counts[date] ?? 0
                            let valid = date <= now && date >= firstDay
                            RoundedRectangle(cornerRadius: 4)
                                .fill(valid ? color(count, maximum: maximum) : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected == date ? Palette.accent : Color.primary.opacity(valid ? 0.06 : 0), lineWidth: selected == date ? 2 : 1))
                                .overlay {
                                    if valid, let values = groupedDays[date], !values.isEmpty, values.allSatisfy({ metric.plottedValue($0) == nil }) {
                                        Text("?").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(height: 21).contentShape(Rectangle())
                                .onTapGesture { if valid { selection = date; focused = true } }
                                .onContinuousHover { phase in if valid, case .active = phase { selection = date } }
                                .help(labels[date] ?? "")
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            // One focus stop and one accessibility element instead of a button per day.
            .focusable().focused($focused).focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accent : .clear, lineWidth: 2).padding(-4))
            .onMoveCommand { direction in
                switch direction {
                case .left: move(by: -7)
                case .right: move(by: 7)
                case .up: move(by: -1)
                case .down: move(by: 1)
                @unknown default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Aktivitätskalender") + " · " + tr(metric.rawValue))
            .accessibilityValue(selected.flatMap { labels[$0] } ?? tr(metric.rawValue))
            .accessibilityHint(tr("Mit den Pfeiltasten einen Tag wählen."))
            .accessibilityAdjustableAction { direction in move(by: direction == .increment ? 1 : -1) }
            HStack(spacing: 4) {
                Text(selected.map { date in
                    date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale)) + ": " + ActivityMetricDetails(groupedDays[date] ?? []).label(metric)
                } ?? tr("Mit den Pfeiltasten einen Tag wählen."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(tr("Wenig")).font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(index == 0 ? Color.primary.opacity(0.05) : Palette.green.opacity(Double(index) / 4)).frame(width: 9, height: 9) }
                Text(tr("Viel")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func move(by days: Int) {
        selection = UsageSelection.move(selected, by: days, in: validDates)
    }
    private func color(_ count: Double, maximum: Double) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.05) }
        let level = max(1, ceil(4 * log1p(Double(count)) / log1p(Double(maximum))))
        return Palette.green.opacity(level / 4)
    }
}
