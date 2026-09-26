import SwiftUI
import JuicebarCore

/// Renders fixture views offscreen; never captures the user's desktop.
@MainActor enum PreviewRenderer {
    static func verifyActivityPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        let event = ActivityEvent(id: "persist", source: .claude, date: Date(), model: "claude-opus-5", tokens: 120, usage: TokenBreakdown(input: 100, output: 20))
        try database.write(ActivityReport(events: [event]), key: "activity-report-v2")
        let reopened = AppStore(directory: directory)
        guard reopened.activity?.days.first?.tokens == 120, reopened.activity?.days.first?.apiCost ?? 0 > 0 else {
            throw ProviderFailure.unavailable("Restart lost the cached usage and cost")
        }
        print("Activity survives restart with costs, before any import starts")
    }
    /// MenuBarExtra proposes an intrinsic size, unlike our fixed-size screenshot previews.
    static func verifyTrayLayout() throws {
        let store = AppStore(demo: true)
        let host = NSHostingView(rootView: TrayMinimumSize { TrayView(store: store, maximumHeight: 1000) })
        let size = host.fittingSize
        print("Tray minimum size: \(Int(size.width)) × \(Int(size.height)); demo accounts: \(store.accounts.count)")
        let capped = NSHostingView(rootView: TrayMinimumSize { TrayView(store: store, maximumHeight: 500) }).fittingSize
        print("Tray with 500 pt available: \(Int(capped.height)) pt")
        guard size.height > 600, size.height < 1000, abs(capped.height - 500) < 1 else {
            throw ProviderFailure.unavailable("Tray must fit all demo accounts and only scroll at the available screen height")
        }
        let claudeID = store.accounts.first { $0.provider == .claude }!.id
        store.snapshots[claudeID]?.windows.append(QuotaWindow(id: "nimbus_quill", title: "Nimbus Quill", usedPercent: 0))
        let withNimbus = NSHostingView(rootView: TrayMinimumSize { TrayView(store: store, maximumHeight: 1000) }).fittingSize
        guard abs(withNimbus.height - size.height) < 1 else {
            throw ProviderFailure.unavailable("Nimbus Quill must not occupy popover space")
        }
        for index in 0..<20 {
            store.snapshots[claudeID]?.windows.append(QuotaWindow(id: "extra-\(index)", title: "Extra \(index)", usedPercent: 10))
        }
        let manyLimits = NSHostingView(rootView: TrayMinimumSize { TrayView(store: store, maximumHeight: 1000) }).fittingSize
        guard abs(manyLimits.height - 1000) < 1 else {
            throw ProviderFailure.unavailable("Many limits must stay within the screen height")
        }
    }
    static func render() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".artifacts/previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(demo: true)
        for (index, page) in Page.allCases.enumerated() {
            for dark in [false, true] {
                let width: CGFloat = dark ? 840 : 1060
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                NSApp.appearance = appearance
                let view = DashboardView(store: store, page: page).frame(width: width, height: 760)
                    .environment(\.colorScheme, dark ? .dark : .light)
                try renderView(view, size: NSSize(width: width, height: 760), appearance: appearance,
                               to: directory.appendingPathComponent("\(index)-\(dark ? "dark-narrow" : "light").png"))
            }
        }
        for (name, page) in [("overview", Page.overview), ("usage", Page.usage)] {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try renderView(DashboardView(store: store, page: page).frame(width: 1280, height: 800).environment(\.colorScheme, .dark),
                           size: NSSize(width: 1280, height: 800), appearance: NSAppearance(named: .darkAqua)!,
                           to: directory.appendingPathComponent("store-\(Localization.language)-\(name).png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        try renderView(AboutView().buttonStyle(JuiceButtonStyle()).tint(Palette.accent).padding(24).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 640, height: 360), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("about.png"))
        try renderView(TrayView(store: store).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSHostingView(rootView: TrayView(store: store)).fittingSize, appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("tray.png"))
        try renderView(AccountEditor(store: store, configuration: AccountConfiguration(provider: .openaiAPI)).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 600, height: 540), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("account-editor.png"))
        try renderView(AccountEditor(store: store, configuration: AccountConfiguration(provider: .opencodeGo)).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 600, height: 780), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("go-editor.png"))
        try renderView(AddResetView(store: store).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 536, height: 350), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("reset-editor.png"))
        try renderView(DashboardView(store: store, page: .alerts).frame(width: 1060, height: 1600),
                       size: NSSize(width: 1060, height: 1600), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("warnings-full.png"))
        try renderView(DashboardView(store: store, page: .usage).frame(width: 1060, height: 1800),
                       size: NSSize(width: 1060, height: 1800), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("usage-full.png"))
        try renderView(TrayLabel(store: store).padding(12).background(Color.white),
                       size: NSSize(width: 360, height: 45), appearance: NSAppearance(named: .aqua)!, to: directory.appendingPathComponent("menubar.png"))
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try renderView(TrayLabel(store: store).padding(12).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark),
                       size: NSSize(width: 360, height: 45), appearance: NSAppearance(named: .darkAqua)!, to: directory.appendingPathComponent("menubar-dark.png"))
        // Website artwork uses the exact menu image shown by the shipping app.
        let menuImage = MenuLimitImage.make(meters: store.trayMeters, mode: store.settings.displayMode,
                                           dark: true, expiring: store.expiringCount > 0)
        let pixels = NSSize(width: menuImage.size.width * 2, height: menuImage.size.height * 2)
        guard let menuBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: menuBitmap) else {
            throw ProviderFailure.unavailable("Menu artwork bitmap unavailable")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        menuImage.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let menuPNG = menuBitmap.representation(using: .png, properties: [:]) else {
            throw ProviderFailure.unavailable("Menu artwork encoding failed")
        }
        try menuPNG.write(to: directory.appendingPathComponent("menu-limits.png"))
        try renderMenuPopover(store: store, to: directory.appendingPathComponent("menu-popover-\(Localization.language).png"))
        print("Rendered previews: \(directory.path)")
    }
    /// The shipping views with fixture data, staged without unrelated desktop apps.
    private static func renderMenuPopover(store: AppStore, to url: URL) throws {
        let appearance = NSAppearance(named: .darkAqua)!
        NSApp.appearance = appearance
        let tray = TrayView(store: store, maximumHeight: 1000)
            .environment(\.colorScheme, .dark)
        let traySize = NSHostingView(rootView: tray).fittingSize
        try renderView(tray.background(Color(nsColor: .windowBackgroundColor)), size: traySize,
                       appearance: appearance,
                       to: url.deletingLastPathComponent().appendingPathComponent("tray-dark-\(Localization.language).png"))
        let view = VStack(alignment: .leading, spacing: 0) {
            HStack {
                TrayLabel(store: store)
                    .padding(.horizontal, 10).frame(height: 25)
                    .background(.white.opacity(0.10), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 24).frame(height: 34)
            .background(Color(red: 0.24, green: 0.28, blue: 0.33))
            tray
                .frame(width: traySize.width, height: traySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
                .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 16)
        }
        .frame(width: traySize.width + 28)
        .background(Color(red: 0.10, green: 0.12, blue: 0.14))
        .environment(\.colorScheme, .dark)
        try renderView(view, size: NSSize(width: traySize.width + 28, height: traySize.height + 56),
                       appearance: appearance, to: url)
    }
    private static func renderView<V: View>(_ view: V, size: NSSize, appearance: NSAppearance, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance
        let host = NSHostingView(rootView: view); host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProviderFailure.unavailable("Preview bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ProviderFailure.unavailable("Preview encoding failed") }
        try data.write(to: url); window.close()
    }
}

private struct TrayMinimumSize: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: 380, height: 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
