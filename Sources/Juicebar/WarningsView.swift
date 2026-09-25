import SwiftUI
import JuicebarCore

struct WarningsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: tr("Früh genug Bescheid wissen."), subtitle: tr("Einmal pro Regel und Zeitfenster. Ohne wiederkehrende Pop-ups bei jedem Abruf."))
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Benachrichtigungen")).font(.headline)
                            Text(store.notificationStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.settings.notificationsEnabled {
                            Button(tr("Deaktivieren")) { store.settings.notificationsEnabled = false }
                        } else { Button(tr("Aktivieren")) { Task { await store.enableNotifications() } }.buttonStyle(JuiceButtonStyle(prominent: true)).disabled(store.isDemo) }
                    }
                    Toggle(tr("Hinweiston abspielen"), isOn: $store.settings.soundEnabled)
                    Text(tr("Nur in der Mitteilungszentrale sichtbar? macOS kann Banner und Ton während einer Bildschirmfreigabe oder bei aktivem Fokus unterdrücken, auch wenn beides für Juicebar erlaubt ist.")).font(.caption).foregroundStyle(.secondary)
                    Button(tr("macOS-Mitteilungseinstellungen öffnen")) { store.openNotificationSettings() }.disabled(store.isDemo)
                    HStack {
                        Button(tr("Testbenachrichtigung")) { Task { await store.testNotification() } }.disabled(!store.settings.notificationsEnabled || store.isDemo)
                        Button(tr("1 Stunde stummschalten")) { store.snooze() }
                        if let until = store.settings.snoozedUntil, until > store.now {
                            Text(tr("Stumm bis {0}", until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.locale)))).font(.caption).foregroundStyle(.secondary)
                            Button(tr("Aufheben")) { store.settings.snoozedUntil = nil }
                        }
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 22) {
                    Text(tr("Verbrauch")).font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tr("Bei Erreichen einer Verbrauchsschwelle"), isOn: $store.settings.thresholdEnabled)
                        HStack { Slider(value: $store.settings.threshold, in: 10...95, step: 5); Text("\(Int(store.settings.threshold)) %").monospacedDigit().frame(width: 50) }.disabled(!store.settings.thresholdEnabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tr("Bei zu hohem Verbrauch für den bisherigen Zeitraum"), isOn: $store.settings.paceEnabled)
                        Stepper(tr("Toleranz: {0} Prozentpunkte", Int(store.settings.paceBuffer)), value: $store.settings.paceBuffer, in: 0...40, step: 5).disabled(!store.settings.paceEnabled)
                        Text(tr("Beispiel: Nach der halben Woche wären 50 % gleichmäßig. Mit 10 Punkten Toleranz warnt Juicebar oberhalb von 60 %.")).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tr("Bei voraussichtlicher Ausschöpfung vor dem Reset"), isOn: $store.settings.forecastEnabled)
                        Stepper(tr("Vorwarnzeit: {0} Stunden", store.settings.forecastHours.formatted()), value: $store.settings.forecastHours, in: 0.5...12, step: 0.5).disabled(!store.settings.forecastEnabled)
                        Text(tr("Schätzung aus aktuellen Messpunkten. Nach Pausen, bei unbekannten Zeitfenstern und ohne ausreichend Verlauf erscheint keine Prognose.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(tr("An ablaufende Reset-Angebote erinnern"), isOn: $store.settings.expiryEnabled).font(.headline)
                    ForEach([72.0, 24.0, 3.0], id: \.self) { hours in
                        Toggle(hours == 72 ? tr("3 Tage vorher") : hours == 24 ? tr("1 Tag vorher") : tr("3 Stunden vorher"), isOn: Binding(get: { store.settings.expiryHours.contains(hours) }, set: { enabled in
                            store.settings.expiryHours.removeAll { $0 == hours }; if enabled { store.settings.expiryHours.append(hours) }
                        })).disabled(!store.settings.expiryEnabled)
                    }
                    Text(tr("Bei später Erkennung zählt die dringendste Stufe. Ohne bekanntes Ablaufdatum wird keine Frist erfunden.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(tr("Nachtruhe"), isOn: $store.settings.quietEnabled).font(.headline)
                    HStack {
                        JuiceMenuPicker(title: tr("Von"), selection: $store.settings.quietStart, options: (0..<24).map { (String(format: "%02d:00", $0), $0) })
                        JuiceMenuPicker(title: tr("Bis"), selection: $store.settings.quietEnd, options: (0..<24).map { (String(format: "%02d:00", $0), $0) })
                    }.disabled(!store.settings.quietEnabled)
                    Text(tr("Während der Nachtruhe und im Ruhezustand gibt es keine Warnungen. Noch gültige Hinweise werden danach geprüft.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("Zuletzt zugestellt")).font(.headline)
                    if store.warnings.isEmpty { Text(tr("Noch keine Warnungen. Erst nach der Aktivierung werden Benachrichtigungen zugestellt.")).font(.callout).foregroundStyle(.secondary) }
                    ForEach(store.warnings.prefix(30)) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.message).font(.callout)
                            Text("\(event.title) · \(event.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale)))").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
        }.onChange(of: store.settings) { _, _ in store.persistSettings() }
    }
}
