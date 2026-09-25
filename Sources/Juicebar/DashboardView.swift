import SwiftUI
import JuicebarCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "Übersicht", usage = "Nutzung", resets = "Resets", alerts = "Warnungen", accounts = "Konten", settings = "Einstellungen"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .usage: return "chart.xyaxis.line"
        case .resets: return "arrow.counterclockwise"
        case .alerts: return "bell"
        case .accounts: return "person.crop.rectangle"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @State private var page: Page = .overview
    init(store: AppStore, page: Page = .overview) {
        self.store = store; _page = State(initialValue: page)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    JuiceGlass(fill: 0.65, color: Palette.accent).frame(width: 23, height: 29)
                    Text("juicebar").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
                }.padding(.horizontal, 22).padding(.top, 42).padding(.bottom, 36)
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.rawValue)
                            Spacer()
                            if item == .resets && store.expiringCount > 0 {
                                Text("\(store.expiringCount)").font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.12), in: Capsule())
                            }
                        }.font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .foregroundStyle(page == item ? Palette.accent : Color.primary.opacity(0.75))
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(page == item ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 3)
                        .accessibilityIdentifier("nav-\(item.id)")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.isDemo ? "Beispieldaten" : "Bleibt auf deinem Mac", systemImage: store.isDemo ? "testtube.2" : "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                    Text(store.isDemo ? "Demo · keine Abfragen" : "Keine Telemetrie.\nKeine Gesprächsinhalte.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(22)
            }.frame(width: 190).background(Palette.sidebar)
            Divider()
            VStack(spacing: 0) {
                if page != .overview && page != .usage {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(store.isPaused ? Color.secondary : store.failures.isEmpty ? Palette.green : Color.orange).frame(width: 6, height: 6)
                            Text(store.isDemo ? "Demo" : store.isPaused ? "Pausiert" : store.isRefreshing ? "Wird aktualisiert …" : !store.failures.isEmpty ? "Nicht alle Konten erreichbar" : updatedText(store.lastChecked, now: store.now))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        refreshButton
                    }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
                    Divider().opacity(0.4)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = store.storageError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                        switch page {
                        case .overview: overview
                        case .usage: UsageView(store: store)
                        case .resets: ResetsView(store: store)
                        case .alerts: WarningsView(store: store)
                        case .accounts: AccountsView(store: store)
                        case .settings: PreferencesView(store: store)
                        }
                    }.padding(28).frame(maxWidth: 1060, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(Palette.accent).buttonStyle(JuiceButtonStyle()).environment(\.quotaDisplay, store.settings.displayMode)
    }
    private var refreshButton: some View {
        Button { store.refresh(force: true) } label: {
            Label(store.isRefreshing ? "Wird aktualisiert …" : "Aktualisieren", systemImage: "arrow.clockwise")
        }.disabled(store.isRefreshing || store.isDemo).controlSize(.small).keyboardShortcut("r")
    }
    private var overviewAccounts: [AccountConfiguration] { QuotaOrder.accounts(store.accounts.filter(\.enabled)) }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                PageHeading(title: "Alles im Blick.", subtitle: "Deine Kontingente, ihr nächster Reset und wie viel Spielraum bleibt.")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    refreshButton
                    if store.isPaused { Text("Abfragen pausiert").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 3)
            }.padding(.top, 10)
            if store.expiringCount > 0 {
                Button { page = .resets } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hourglass").font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(store.expiringCount == 1 ? "Ein Reset läuft" : "\(store.expiringCount) Resets laufen") bald ab").font(.system(size: 13, weight: .semibold))
                            Text("Fristen ansehen und rechtzeitig beim Anbieter einlösen.").font(.system(size: 12)).foregroundStyle(Color.secondary)
                        }
                        Spacer(); Image(systemName: "arrow.up.right")
                    }.padding(17).foregroundStyle(Palette.accent)
                        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
            if store.accounts.filter(\.enabled).isEmpty {
                Panel { EmptyState(symbol: "plus.circle", title: "Dein erster Überblick", message: "Füge ein Konto hinzu, um Verbrauch und Resetzeiten zu sehen.")
                    Button("Konto hinzufügen") { page = .accounts }.buttonStyle(JuiceButtonStyle(prominent: true)) }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<min(2, overviewAccounts.count), id: \.self) { column in
                        VStack(spacing: 18) {
                            ForEach(Array(overviewAccounts.enumerated()).filter { $0.offset % 2 == column }.map(\.element)) { account in
                                AccountCard(store: store, account: account) { page = .accounts }
                            }
                        }.frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                HStack(spacing: 7) {
                    Rectangle().fill(.secondary).frame(width: 2, height: 10)
                    Text("Die Markierung zeigt den Sollstand bei gleichmäßiger Nutzung. Jeder Balken gehört zu einem eigenen Limit.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !store.settings.notificationsEnabled {
                Panel {
                    HStack(spacing: 16) {
                        Image(systemName: "bell.badge").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rechtzeitig Bescheid wissen").font(.system(size: 14, weight: .semibold))
                            Text("Warnungen bei 50 %, hohem Tempo und ablaufenden Resets.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Einrichten") { page = .alerts }.buttonStyle(JuiceButtonStyle())
                    }
                }
            }
        }
    }
}

struct AccountCard: View {
    @ObservedObject var store: AppStore
    let account: AccountConfiguration
    let manage: () -> Void
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    ProviderMark(kind: account.provider)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName).font(.system(size: 15, weight: .semibold))
                        Text(store.snapshots[account.id]?.plan.capitalized ?? "Noch nicht verbunden").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.refreshingAccount == account.id { ProgressView().controlSize(.small) }
                    else if let snapshot = store.snapshots[account.id], !snapshot.isFresh(at: store.now) || store.failures[account.id] != nil {
                        Text("Letzter Stand").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                if let snapshot = store.snapshots[account.id] {
                    ForEach(QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)) { window in
                        QuotaBar(window: window, color: Palette.provider(account.provider), now: store.now)
                    }
                    ForEach(snapshot.money) { metric in
                        HStack {
                            Text(metric.title).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(metric.currency == "Credits" ? "\(metric.amount.formatted(.number.precision(.fractionLength(0...1)))) Credits" : metric.amount.formatted(.currency(code: metric.currency)))
                                .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                    }
                    if let count = snapshot.benefitCount, count > 0 {
                        ResetAvailability(snapshot: snapshot, now: store.now)
                    }
                    if snapshot.windows.isEmpty && snapshot.money.isEmpty, let notice = snapshot.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else if store.refreshingAccount == account.id {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Verbrauch wird abgefragt …").font(.callout)
                        Text("Die Anmeldung bleibt bei deinem Anbieter.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.failures[account.id] ?? "Beim nächsten Abruf erscheinen hier deine Kontingente.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Verbindung einrichten", action: manage).buttonStyle(JuiceButtonStyle())
                    }.padding(.vertical, 8)
                }
                if let error = store.failures[account.id], store.snapshots[account.id] != nil {
                    Label(error, systemImage: "wifi.exclamationmark").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(updatedText(store.snapshots[account.id]?.observedAt, now: store.now)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button { store.openAccount(account) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("\(account.provider.name) im Browser öffnen")
                }
            }
        }
    }
}
