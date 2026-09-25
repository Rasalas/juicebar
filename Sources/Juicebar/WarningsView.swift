import SwiftUI
import JuicebarCore

struct WarningsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "Früh genug Bescheid wissen.", subtitle: "Einmal pro Regel und Zeitfenster. Ohne wiederkehrende Pop-ups bei jedem Abruf.")
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Benachrichtigungen").font(.headline)
                            Text(store.notificationStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.settings.notificationsEnabled {
                            Button("Deaktivieren") { store.settings.notificationsEnabled = false }
                        } else { Button("Aktivieren") { Task { await store.enableNotifications() } }.buttonStyle(JuiceButtonStyle(prominent: true)).disabled(store.isDemo) }
                    }
                    Toggle("Hinweiston abspielen", isOn: $store.settings.soundEnabled)
                    Text("Nur in der Mitteilungszentrale sichtbar? macOS kann Banner und Ton während einer Bildschirmfreigabe oder bei aktivem Fokus unterdrücken, auch wenn beides für Juicebar erlaubt ist.").font(.caption).foregroundStyle(.secondary)
                    Button("macOS-Mitteilungseinstellungen öffnen") { store.openNotificationSettings() }.disabled(store.isDemo)
                    HStack {
                        Button("Testbenachrichtigung") { Task { await store.testNotification() } }.disabled(!store.settings.notificationsEnabled || store.isDemo)
                        Button("1 Stunde stummschalten") { store.snooze() }
                        if let until = store.settings.snoozedUntil, until > store.now {
                            Text("Stumm bis \(until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            Button("Aufheben") { store.settings.snoozedUntil = nil }
                        }
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Verbrauch").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bei Erreichen einer Verbrauchsschwelle", isOn: $store.settings.thresholdEnabled)
                        HStack { Slider(value: $store.settings.threshold, in: 10...95, step: 5); Text("\(Int(store.settings.threshold)) %").monospacedDigit().frame(width: 50) }.disabled(!store.settings.thresholdEnabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bei zu hohem Verbrauch für den bisherigen Zeitraum", isOn: $store.settings.paceEnabled)
                        Stepper("Toleranz: \(Int(store.settings.paceBuffer)) Prozentpunkte", value: $store.settings.paceBuffer, in: 0...40, step: 5).disabled(!store.settings.paceEnabled)
                        Text("Beispiel: Nach der halben Woche wären 50 % gleichmäßig. Mit 10 Punkten Toleranz warnt Juicebar oberhalb von 60 %.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bei voraussichtlicher Ausschöpfung vor dem Reset", isOn: $store.settings.forecastEnabled)
                        Stepper("Vorwarnzeit: \(store.settings.forecastHours.formatted()) Stunden", value: $store.settings.forecastHours, in: 0.5...12, step: 0.5).disabled(!store.settings.forecastEnabled)
                        Text("Schätzung aus aktuellen Messpunkten. Nach Pausen, bei unbekannten Zeitfenstern und ohne ausreichend Verlauf erscheint keine Prognose.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("An ablaufende Reset-Angebote erinnern", isOn: $store.settings.expiryEnabled).font(.headline)
                    ForEach([72.0, 24.0, 3.0], id: \.self) { hours in
                        Toggle(hours == 72 ? "3 Tage vorher" : hours == 24 ? "1 Tag vorher" : "3 Stunden vorher", isOn: Binding(get: { store.settings.expiryHours.contains(hours) }, set: { enabled in
                            store.settings.expiryHours.removeAll { $0 == hours }; if enabled { store.settings.expiryHours.append(hours) }
                        })).disabled(!store.settings.expiryEnabled)
                    }
                    Text("Bei später Erkennung zählt die dringendste Stufe. Ohne bekanntes Ablaufdatum wird keine Frist erfunden.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Nachtruhe", isOn: $store.settings.quietEnabled).font(.headline)
                    HStack {
                        JuiceMenuPicker(title: "Von", selection: $store.settings.quietStart, options: (0..<24).map { (String(format: "%02d:00", $0), $0) })
                        JuiceMenuPicker(title: "Bis", selection: $store.settings.quietEnd, options: (0..<24).map { (String(format: "%02d:00", $0), $0) })
                    }.disabled(!store.settings.quietEnabled)
                    Text("Während der Nachtruhe und im Ruhezustand gibt es keine Warnungen. Noch gültige Hinweise werden danach geprüft.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Zuletzt zugestellt").font(.headline)
                    if store.warnings.isEmpty { Text("Noch keine Warnungen. Erst nach der Aktivierung werden Benachrichtigungen zugestellt.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(store.warnings.prefix(30)) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.message).font(.callout)
                            Text("\(event.title) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
        }.onChange(of: store.settings) { _, _ in store.persistSettings() }
    }
}
