import SwiftUI
import JuicebarCore

struct WorkScheduleEditor: View {
    @Binding var schedule: WorkSchedule?
    private let weekdays: [(Int, String, String)] = [
        (2, "Mo", "Montag"), (3, "Di", "Dienstag"), (4, "Mi", "Mittwoch"), (5, "Do", "Donnerstag"),
        (6, "Fr", "Freitag"), (7, "Sa", "Samstag"), (1, "So", "Sonntag")
    ]
    private var value: WorkSchedule { schedule ?? WorkSchedule() }
    private func update(_ change: (inout WorkSchedule) -> Void) {
        var value = self.value; change(&value); schedule = value
    }
    private var enabled: Binding<Bool> {
        Binding(get: { value.isEnabled }, set: { selected in update { $0.isEnabled = selected } })
    }
    private func selected(_ day: Int) -> Binding<Bool> {
        Binding(get: { value.weekdays.contains(day) }, set: { selected in
            update { if selected { $0.weekdays.insert(day) } else { $0.weekdays.remove(day) } }
        })
    }
    private func time(_ path: WritableKeyPath<WorkSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = value[keyPath: path]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            update { $0[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(tr("Arbeitsplan"), isOn: enabled).accessibilityIdentifier("work-schedule-enabled")
            if value.isEnabled {
                HStack(spacing: 5) {
                    ForEach(weekdays, id: \.0) { day, label, name in
                        let active = value.weekdays.contains(day)
                        Button { selected(day).wrappedValue.toggle() } label: {
                            Text(tr(label)).font(.callout.weight(active ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .foregroundStyle(active ? Palette.green : Color.secondary)
                                .background(active ? Palette.green.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .accessibilityLabel(tr(name)).accessibilityIdentifier("work-schedule-day-\(day)")
                    }
                }
                HStack(spacing: 16) {
                    DatePicker(tr("Von"), selection: time(\.startMinute), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("work-schedule-start")
                    DatePicker(tr("Bis"), selection: time(\.endMinute), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("work-schedule-end")
                }
            }
        }.tint(Palette.green)
    }
}
