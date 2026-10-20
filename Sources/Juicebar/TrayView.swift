import SwiftUI
import JuicebarCore

struct TrayView: View {
    let store: AppStore
    var maximumHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 800) - 16
    @State private var height: CGFloat = 0
    // The sections render three times for layout; quota projections run once here.
    private var rows: [TrayAccountRow] {
        QuotaOrder.accounts(store.accounts.filter(\.enabled)).map { account in
            let snapshot = store.snapshots[account.id], failure = store.failures[account.id]
            let windows = snapshot.map { snapshot in
                QuotaOrder.visibleWindows(snapshot.windows, provider: account.provider).map { window in
                    TrayWindowRow(window: window, status: QuotaStatus.assess(window: window, snapshot: snapshot, history: store.history[account.id] ?? [],
                                                                             now: store.now, hasFailure: failure != nil))
                }
            } ?? []
            return TrayAccountRow(account: account, snapshot: snapshot, failure: failure, windows: windows)
        }
    }
    var body: some View {
        let rows = self.rows, expiring = store.expiringCount
        TrayLayout(maximumHeight: maximumHeight - 32) {
            HStack(spacing: 8) {
                Button { DashboardWindow.shared.show(store: store) } label: {
                    HStack(spacing: 7) {
                        JuiceLogo().frame(width: 22, height: 22)
                        Text("juicebars").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(-0.5)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(tr("Juicebars öffnen")).accessibilityLabel(tr("Juicebars öffnen"))
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 14, height: 14) }
                    .disabled(store.isPaused || store.isDemo).help(tr("Aktualisieren")).accessibilityLabel(tr("Aktualisieren"))
                Menu {
                    Button(store.isPaused ? tr("Abfragen fortsetzen") : tr("Abfragen pausieren")) { store.isPaused.toggle(); if !store.isPaused { store.refresh(force: true) } }
                    Button(tr("Warnungen 1 Stunde stummschalten")) { store.snooze() }
                    Divider()
                    Button(tr("Einstellungen …")) { DashboardWindow.shared.show(store: store, page: .settings) }.keyboardShortcut(",")
                    Button(tr("Juicebars beenden")) { store.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis").frame(width: 14, height: 14) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(JuiceButtonStyle()).fixedSize()
                    .help(tr("Weitere Aktionen")).accessibilityLabel(tr("Weitere Aktionen"))
            }
            accountSections(rows).hidden().accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                accountSections(rows)
                ScrollView { accountSections(rows).padding(.bottom, 18) }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // Indicators stay hidden, so a fade shows that more accounts follow.
                    .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28) })
            }
            VStack(alignment: .leading, spacing: 10) {
                if expiring > 0 {
                    Label(expiring == 1 ? tr("1 Reset-Gutschrift läuft in den nächsten 3 Tagen ab") : tr("{0} Reset-Gutschriften laufen in den nächsten 3 Tagen ab", expiring), systemImage: "hourglass")
                        .font(.caption).foregroundStyle(Palette.warning)
                }
                HStack {
                    Label(tr("Soll = gleichmäßiger Verbrauch"), systemImage: "diamond.fill")
                    Spacer(minLength: 4)
                    Text(store.isDemo ? tr("Beispieldaten") : store.isPaused ? tr("Pausiert") : updatedText(store.lastChecked, now: store.now))
                }.font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 380).background(.ultraThinMaterial)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .background(TrayWindowFit(height: height))
        .tint(Palette.accent).buttonStyle(JuiceButtonStyle())
        .environment(\.quotaDisplay, store.settings.displayMode).environment(\.locale, Localization.locale).onAppear { store.start() }
    }
    private func accountSections(_ rows: [TrayAccountRow]) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Noch keine aktiven Konten. Füge unter Konten ein Abo oder einen API-Key hinzu."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(tr("Konto hinzufügen")) { DashboardWindow.shared.show(store: store, page: .accounts) }
                        .buttonStyle(JuiceButtonStyle(prominent: true))
                }.padding(.vertical, 12)
            }
            ForEach(rows) { row in
                TrayAccountView(store: store, row: row, now: store.now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// MenuBarExtra grows its window with the content but never shrinks it; the rest stays transparent.
private struct TrayWindowFit: NSViewRepresentable {
    let height: CGFloat
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard height > 0, let window = view.window, abs(window.contentLayoutRect.height - height) >= 0.5 else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: window.contentLayoutRect.width, height: height)))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
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

private struct TrayWindowRow: Identifiable {
    let window: QuotaWindow
    let status: QuotaStatus
    var id: String { window.id }
}

private struct TrayAccountRow: Identifiable {
    let account: AccountConfiguration
    let snapshot: AccountSnapshot?
    let failure: String?
    let windows: [TrayWindowRow]
    var id: String { account.id }
}

private struct TrayAccountView: View {
    let store: AppStore
    let row: TrayAccountRow
    let now: Date
    private var account: AccountConfiguration { row.account }
    private var snapshot: AccountSnapshot? { row.snapshot }
    private var stale: Bool { snapshot?.isFresh(at: now) != true || row.failure != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderMark(kind: account.provider, size: 20)
                Text(account.displayName).font(.body.weight(.semibold))
                if let plan = snapshot?.plan, !plan.isEmpty {
                    Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let snapshot, stale {
                    Text(lastValueText(snapshot.observedAt, now: now)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = row.failure {
                AccountFailureView(store: store, account: account, failure: failure)
            }
            if let snapshot {
                VStack(spacing: 14) {
                    ForEach(row.windows) { item in
                        QuotaBar(window: item.window, color: Palette.provider(account.provider), now: now, compact: true, status: item.status)
                    }
                }
                ForEach(snapshot.money) { metric in
                    HStack {
                        Text(metric.title).foregroundStyle(.secondary)
                        Spacer()
                        Text(moneyText(metric))
                    }.font(.subheadline).monospacedDigit()
                }
                if let count = snapshot.benefitCount, count > 0 {
                    ResetAvailability(snapshot: snapshot, now: now)
                }
                if row.windows.isEmpty && snapshot.money.isEmpty {
                    Text(snapshot.notice ?? tr("Keine Kontingente verfügbar")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if row.failure == nil && snapshot == nil {
                Text(tr("Verbindung wird hergestellt …")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }
}
