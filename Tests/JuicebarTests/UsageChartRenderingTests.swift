import XCTest
import SwiftUI
import JuicebarCore
@testable import Juicebar

/// Optional native fixture rendering. No AppStore, provider, installed app or saved defaults are changed.
@MainActor final class UsageChartRenderingTests: XCTestCase {
    func testRenderInspectionStates() throws {
        guard let path = ProcessInfo.processInfo.environment["JUICEBAR_USAGE_RENDER_DIR"] else {
            throw XCTSkip("Set JUICEBAR_USAGE_RENDER_DIR to render synthetic inspection states offscreen")
        }
        // Argument-domain defaults live only in this test process, never in the installed app's settings.
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["appLanguage"] = ProcessInfo.processInfo.environment["JUICEBAR_USAGE_RENDER_LANGUAGE"] == "de" ? "de" : "en"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15))!
        let dates = UsageSelection.days(ending: now, count: 30)
        let events = [
            ActivityEvent(id: "priced", source: .codex, date: now, model: "gpt-5.4-mini", tokens: 1234567, usage: TokenBreakdown(input: 1234000, output: 567)),
            ActivityEvent(id: "unknown", source: .claude, date: now, model: "unpriced-model", tokens: 2400),
            ActivityEvent(id: "logged-zero", source: .pi, date: now.addingTimeInterval(-86400), model: "fixture", tokens: 600, reportedCost: 0)
        ]
        let days = ActivityReport(events: events, now: now).days
        var archived = days.first!
        archived.day = dates[dates.count - 3]; archived.source = .claude
        archived.tokens = 0; archived.responses = 0; archived.apiCost = 0; archived.pricedTokens = 0
        archived.unpricedModels = []; archived.archivedMessages = 423
        let values = days + [archived]
        let quotas = [
            QuotaPoint(date: now.addingTimeInterval(-7200), value: 15.125, label: "Fixture · Week", series: "fixture|week"),
            QuotaPoint(date: now.addingTimeInterval(-3600), value: 17.875, label: "Fixture · Week", series: "fixture|week"),
            QuotaPoint(date: now, value: 18.25, label: "Fixture · Week", series: "fixture|week"),
            QuotaPoint(date: now, value: 102.125, label: "Fixture · Session", series: "fixture|session"),
            QuotaPoint(date: now.addingTimeInterval(-3600), value: 100, label: "Fixture · Session", series: "fixture|previous-session")
        ]
        for dark in [false, true] {
            for metric in ActivityMetric.allCases {
                let view = VStack(alignment: .leading, spacing: 24) {
                    Text(tr(metric.rawValue)).font(.title2)
                    ActivityCalendar(days: values, now: now, numberOfDays: 30, metric: metric, selection: .constant(dates.last))
                    ActivityDailyChart(days: values, dates: dates, metric: metric, selection: .constant(dates.last))
                    QuotaTimelineChart(points: quotas, displayLabel: tr("Verbraucht"), selection: quotas[1].id)
                }
                try render(view, width: dark ? 600 : 820, dark: dark, to: directory.appendingPathComponent("inspection-\(metric.id)-\(dark ? "dark" : "light").png"))
            }
        }
        let edgeCases: [(String, [ActivityDay], [QuotaPoint], Date?)] = [
            ("empty", [], [], dates.last),
            ("archive", [archived], Array(quotas.suffix(1)), archived.day),
            ("unpriced", days.filter { $0.source == .claude }, Array(quotas.suffix(1)), dates.last),
            ("logged-zero", days.filter { $0.source == .pi }, Array(quotas.suffix(1)), dates.dropLast().last)
        ]
        for (name, activity, points, selection) in edgeCases {
            let view = VStack(alignment: .leading, spacing: 24) {
                ActivityCalendar(days: activity, now: now, numberOfDays: 30, metric: .cost, selection: .constant(selection))
                ActivityDailyChart(days: activity, dates: dates, metric: .cost, selection: .constant(selection))
                QuotaTimelineChart(points: points, displayLabel: tr("Verbraucht"))
            }
            try render(view, width: 600, dark: false, to: directory.appendingPathComponent("inspection-\(name).png"))
        }
    }
    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let content = view.padding(24).frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
