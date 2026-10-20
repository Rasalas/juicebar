import SwiftUI
import JuicebarCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "Übersicht", usage = "Nutzung", resets = "Resets", alerts = "Warnungen", accounts = "Konten", settings = "Einstellungen"
    var id: String { rawValue }
    var title: String { self == .resets ? tr("Gutschriften") : tr(rawValue) }
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

/// Lets the popover, the menu and ⌘, open a specific dashboard page or account editor.
@MainActor @Observable final class DashboardNavigation {
    static let shared = DashboardNavigation()
    var page: Page?
    var editAccountID: String?
}

struct DashboardView: View {
    let store: AppStore
    @State private var page: Page = .overview
    @FocusState private var focusedPage: Page?
    private let navigation = DashboardNavigation.shared
    init(store: AppStore, page: Page = .overview) {
        self.store = store; _page = State(initialValue: page)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    JuiceLogo().frame(width: 29, height: 29)
                    Text("juicebars").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
                }.padding(.horizontal, 22).padding(.top, 42).padding(.bottom, 36)
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.title).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            if item == .resets && store.expiringCount > 0 {
                                Text("\(store.expiringCount)").font(.caption.weight(.bold)).foregroundStyle(Palette.warning)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.warning.opacity(0.15), in: Capsule())
                                    .accessibilityLabel(tr("{0} bald ablaufend", store.expiringCount))
                            }
                        }.font(.body.weight(page == item ? .semibold : .regular))
                            .foregroundStyle(page == item ? Palette.accent : Color.primary.opacity(0.75))
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(page == item ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .focused($focusedPage, equals: item)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focusedPage == item ? Palette.accent : .clear, lineWidth: 2))
                        .padding(.horizontal, 12).padding(.bottom, 3)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                        .accessibilityIdentifier("nav-\(item.id)")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.isDemo ? tr("Beispieldaten") : tr("Bleibt auf deinem Mac"), systemImage: store.isDemo ? "testtube.2" : "lock.shield")
                        .font(.subheadline.weight(.medium))
                    Text(store.isDemo ? tr("Demo · keine Abfragen") : tr("Keine Telemetrie.\nKeine Gesprächsinhalte."))
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(22)
            }.frame(width: 190).background(Palette.sidebar)
            Divider()
            VStack(spacing: 0) {
                if page != .overview && page != .usage {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(store.isPaused ? Color.secondary : store.failures.isEmpty ? Palette.green : Palette.warning).frame(width: 6, height: 6)
                            Text(store.isDemo ? "Demo" : store.isPaused ? tr("Pausiert") : store.isRefreshing ? tr("Wird aktualisiert …") : !store.failures.isEmpty ? tr("Nicht alle Konten erreichbar") : updatedText(store.lastChecked, now: store.now))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        refreshButton
                    }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
                    Divider().opacity(0.4)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = store.storageError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Palette.warning)
                            if store.hasRecoverableStorageError {
                                Text(tr("Die beschädigten Originaldaten bleiben gesichert. Nur betroffene Einstellungen werden zurückgesetzt."))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(tr("Beschädigte Einstellungen zurücksetzen")) { store.recoverStoredConfiguration() }
                            }
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
        }.tint(Palette.accent).buttonStyle(JuiceButtonStyle()).environment(\.quotaDisplay, store.settings.displayMode).environment(\.locale, Localization.locale)
            .onChange(of: navigation.page, initial: true) { _, requested in
                guard let requested else { return }
                page = requested; navigation.page = nil
            }
    }
    private var refreshButton: some View {
        Button { store.refresh(force: true) } label: {
            Label(store.isRefreshing ? tr("Wird aktualisiert …") : tr("Aktualisieren"), systemImage: "arrow.clockwise")
        }.disabled(store.isPaused || store.isDemo).controlSize(.small).keyboardShortcut("r")
    }
    private var overviewAccounts: [AccountConfiguration] { QuotaOrder.accounts(store.accounts.filter(\.enabled)) }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                PageHeading(title: tr("Alles im Blick."), subtitle: tr("Deine Kontingente, ihr nächster Reset und wie viel Spielraum bleibt."))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    refreshButton
                    if store.isPaused { Text(tr("Abfragen pausiert")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 3)
            }.padding(.top, 10)
            if store.expiringCount > 0 {
                Button { page = .resets } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hourglass").font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.expiringCount == 1 ? tr("Eine Reset-Gutschrift läuft bald ab") : tr("{0} Reset-Gutschriften laufen bald ab", store.expiringCount)).font(.body.weight(.semibold))
                            Text(tr("Fristen ansehen und rechtzeitig beim Anbieter einlösen.")).font(.callout).foregroundStyle(Color.secondary)
                        }
                        Spacer(); Image(systemName: "arrow.up.right")
                    }.padding(17).foregroundStyle(Palette.warning)
                        .background(Palette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
            if store.accounts.filter(\.enabled).isEmpty {
                Panel { EmptyState(symbol: "plus.circle", title: tr("Dein erster Überblick"), message: tr("Füge ein Konto hinzu, um Verbrauch und Resetzeiten zu sehen."))
                    Button(tr("Konto hinzufügen")) { page = .accounts }.buttonStyle(JuiceButtonStyle(prominent: true)) }
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "diamond.fill").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                        Text(tr("Die Raute zeigt den Sollstand bei gleichmäßiger Nutzung. Jeder Balken gehört zu einem eigenen Limit."))
                    }
                    let reaches = overviewAccounts.flatMap { account in store.weeklyReach(for: account).filter(\.isRelevant) }
                    if !reaches.isEmpty { WeeklyReachLegend(expiring: reaches.contains { $0.expiring >= 0.5 }) }
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            if !store.settings.notificationsEnabled {
                Panel {
                    HStack(spacing: 16) {
                        Image(systemName: "bell.badge").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Rechtzeitig Bescheid wissen")).font(.body.weight(.semibold))
                            Text(tr("Warnungen ab {0} % verbraucht, bei hohem Tempo und für ablaufende Reset-Gutschriften.", Int(store.settings.threshold))).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("Einrichten")) { page = .alerts }.buttonStyle(JuiceButtonStyle())
                    }
                }
            }
        }
    }
}

struct AccountCard: View {
    let store: AppStore
    let account: AccountConfiguration
    let manage: () -> Void
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    ProviderMark(kind: account.provider)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName).font(.title3.weight(.semibold))
                        Text(store.snapshots[account.id]?.plan.capitalized ?? tr("Noch nicht verbunden")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.refreshingAccountIDs.contains(account.id) { ProgressView().controlSize(.small) }
                    else if let snapshot = store.snapshots[account.id], !snapshot.isFresh(at: store.now) || store.failures[account.id] != nil {
                        Text(lastValueText(snapshot.observedAt, now: store.now)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                if let failure = store.failures[account.id] {
                    AccountFailureView(store: store, account: account, failure: failure)
                }
                if let snapshot = store.snapshots[account.id] {
                    let reaches = store.weeklyReach(for: account)
                    ForEach(QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider)) { window in
                        QuotaBar(window: window, color: Palette.provider(account.provider), now: store.now,
                                 status: QuotaStatus.assess(window: window, snapshot: snapshot,
                                                          history: store.history[account.id] ?? [], now: store.now,
                                                          hasFailure: store.failures[account.id] != nil),
                                 reach: WeeklyReach.relevant(for: window.id, in: reaches))
                    }
                    ForEach(snapshot.money) { metric in
                        HStack {
                            Text(metric.title).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(moneyText(metric))
                                .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                    }
                    if let count = snapshot.benefitCount, count > 0 {
                        ResetAvailability(snapshot: snapshot, now: store.now)
                    }
                    if snapshot.windows.isEmpty && snapshot.money.isEmpty, let notice = snapshot.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else if store.refreshingAccountIDs.contains(account.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Verbrauch wird abgefragt …")).font(.callout)
                        Text(tr("Die Anmeldung bleibt bei deinem Anbieter.")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                } else if store.failures[account.id] == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("Beim nächsten Abruf erscheinen hier deine Kontingente."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(tr("Verbindung einrichten"), action: manage).buttonStyle(JuiceButtonStyle())
                    }.padding(.vertical, 8)
                }
                HStack {
                    Text(updatedText(store.snapshots[account.id]?.observedAt, now: store.now)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.openAccount(account) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("{0} im Browser öffnen", account.provider.name))
                        .accessibilityLabel(tr("{0} im Browser öffnen", account.provider.name))
                }
            }
        }
    }
}
