import SwiftUI
import JuicebarCore

struct TrayView: View {
    @ObservedObject var store: AppStore
    var maximumHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 800) - 16
    private var accounts: [AccountConfiguration] { QuotaOrder.accounts(store.accounts.filter(\.enabled)) }
    var body: some View {
        TrayLayout(maximumHeight: maximumHeight - 32) {
            HStack(spacing: 8) {
                Button { DashboardWindow.shared.show(store: store) } label: {
                    HStack(spacing: 7) {
                        JuiceLogo().frame(width: 22, height: 22)
                        Text("juicebar").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(-0.5)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(tr("Juicebar öffnen")).accessibilityLabel(tr("Juicebar öffnen"))
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isRefreshing || store.isDemo).help(tr("Aktualisieren"))
                Menu {
                    Button(store.isPaused ? tr("Abfragen fortsetzen") : tr("Abfragen pausieren")) { store.isPaused.toggle(); if !store.isPaused { store.refresh(force: true) } }
                    Button(tr("Warnungen 1 Stunde stummschalten")) { store.snooze() }
                    Divider()
                    Button(tr("Juicebar beenden")) { store.stop(); NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(JuiceButtonStyle()).fixedSize()
                    .help(tr("Weitere Aktionen"))
            }
            accountSections.hidden().accessibilityHidden(true)
            ScrollView { accountSections }.scrollBounceBehavior(.basedOnSize)
            VStack(alignment: .leading, spacing: 10) {
                if store.expiringCount > 0 {
                    Label(tr("{0} {1} in den nächsten 3 Tagen", store.expiringCount, store.expiringCount == 1 ? tr("Reset-Frist") : tr("Reset-Fristen")), systemImage: "hourglass")
                        .font(.caption).foregroundStyle(Palette.accent)
                }
                HStack {
                    Text(tr("Soll = gleichmäßiger Verbrauch"))
                    Spacer(minLength: 4)
                    Text(store.isDemo ? tr("Beispieldaten") : store.isPaused ? tr("Pausiert") : updatedText(store.lastChecked, now: store.now))
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 380).background(.ultraThinMaterial)
        .tint(Palette.accent).buttonStyle(JuiceButtonStyle())
        .environment(\.quotaDisplay, store.settings.displayMode).onAppear { store.start() }
    }
    private var accountSections: some View {
        VStack(alignment: .leading, spacing: 26) {
            if accounts.isEmpty {
                Text(tr("Noch keine aktiven Konten. Verbinde einen Anbieter in der Übersicht."))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(accounts) { account in
                TrayAccountView(store: store, account: account)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// MenuBarExtra proposes zero height. Measure the full content synchronously rather than
/// relying on a ScrollView's minimum size or a later geometry-preference update.
private struct TrayLayout: Layout {
    let maximumHeight: CGFloat
    private let spacing: CGFloat = 12
    private func dimensions(width: CGFloat, subviews: Subviews) -> (header: CGFloat, viewport: CGFloat, footer: CGFloat) {
        let proposal = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(proposal).height
        let content = subviews[1].sizeThatFits(proposal).height
        let footer = subviews[3].sizeThatFits(proposal).height
        let available = max(1, maximumHeight - header - footer - 2 * spacing)
        return (header, min(content, available), footer)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 348
        let sizes = dimensions(width: width, subviews: subviews)
        return CGSize(width: width, height: sizes.header + sizes.viewport + sizes.footer + 2 * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = dimensions(width: bounds.width, subviews: subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: sizes.header))
        let viewportY = bounds.minY + sizes.header + spacing
        subviews[2].place(at: CGPoint(x: bounds.minX, y: viewportY), proposal: ProposedViewSize(width: bounds.width, height: sizes.viewport))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: viewportY + sizes.viewport + spacing), proposal: ProposedViewSize(width: bounds.width, height: sizes.footer))
    }
}

private struct TrayAccountView: View {
    @ObservedObject var store: AppStore
    let account: AccountConfiguration
    private var snapshot: AccountSnapshot? { store.snapshots[account.id] }
    private var visibleWindows: [QuotaWindow] {
        QuotaOrder.visibleWindows(snapshot?.windows ?? [], provider: account.provider)
    }
    private var stale: Bool { snapshot?.isFresh(at: store.now) != true || store.failures[account.id] != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderMark(kind: account.provider, size: 20)
                Text(account.displayName).font(.system(size: 13, weight: .semibold))
                if let plan = snapshot?.plan, !plan.isEmpty {
                    Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if snapshot != nil && stale {
                    Text(tr("Letzter Stand")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                VStack(spacing: 14) {
                    ForEach(visibleWindows) {
                        QuotaBar(window: $0, color: Palette.provider(account.provider), now: store.now, compact: true)
                    }
                }
                ForEach(snapshot.money) { metric in
                    HStack {
                        Text(metric.title).foregroundStyle(.secondary)
                        Spacer()
                        Text(metric.currency == "Credits" ? "\(metric.amount.formatted(.number.precision(.fractionLength(0...1)))) Credits" : metric.amount.formatted(.currency(code: metric.currency)))
                    }.font(.system(size: 11)).monospacedDigit()
                }
                if let count = snapshot.benefitCount, count > 0 {
                    ResetAvailability(snapshot: snapshot, now: store.now)
                }
                if visibleWindows.isEmpty && snapshot.money.isEmpty {
                    Text(snapshot.notice ?? tr("Keine Kontingente verfügbar")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = store.failures[account.id] {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if snapshot == nil {
                Text(tr("Verbindung wird hergestellt …")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }
}
