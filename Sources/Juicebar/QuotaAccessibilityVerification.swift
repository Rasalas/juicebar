import SwiftUI
import JuicebarCore

/// Dedicated synthetic probe. No AppStore, providers, notifications or privacy prompts.
enum QuotaAccessibilityVerification {
    enum Result: Equatable {
        case verified, unavailable, invalid

        func exitCode(strict: Bool) -> Int32 {
            switch self {
            case .verified: return 0
            case .unavailable: return strict ? 1 : 2
            case .invalid: return 1
            }
        }

        var message: String {
            switch self {
            case .verified:
                return "PASS: quota AX button exposes its label, exact reset and pace. VoiceOver interaction remains unverified."
            case .unavailable:
                return "UNAVAILABLE: SwiftUI exposed no quota AX button. No live accessibility or VoiceOver validation performed."
            case .invalid:
                return "FAIL: quota AX button is missing its label, exact reset or pace."
            }
        }
    }

    struct Button {
        var label: String
        var value: String
    }

    static func evaluate(_ buttons: [Button], title: String, reset: String, pace: String) -> Result {
        guard !buttons.isEmpty else { return .unavailable }
        return buttons.contains {
            $0.label.contains(title) && $0.label.contains("50") && $0.value.contains(reset) && $0.value.contains(pace)
        } ? .verified : .invalid
    }

    @MainActor static func run(interactive: Bool) -> Result {
        let now = Date(timeIntervalSince1970: 1_800_000_000), reset = now.addingTimeInterval(3600)
        let quota = QuotaWindow(id: "accessibility", title: "Woche", usedPercent: 50, resetsAt: reset, duration: 7200)
        let host = NSHostingView(rootView: QuotaBar(window: quota, color: .blue, now: now).padding(16).frame(width: 380, height: 160))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Juicebars quota accessibility fixture"
        window.isReleasedWhenClosed = false
        window.contentView = host
        if interactive {
            NSApp.setActivationPolicy(.regular)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let leftEdge = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
            window.setFrameOrigin(NSPoint(x: leftEdge - 5_000, y: 0))
            window.orderFront(nil)
        }
        defer { window.close() }
        func elements(_ item: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 32, let accessible = item as? any NSAccessibilityProtocol else { return [] }
            return [accessible] + (accessible.accessibilityChildren() ?? []).flatMap { elements($0, depth: depth + 1) }
        }
        var result = Result.unavailable
        // SwiftUI adapters can appear after the first layout. Keep the retry bounded.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let center = window.convertPoint(toScreen: NSPoint(x: 190, y: 80))
            let navigation = host.accessibilityChildrenInNavigationOrder() ?? []
            let tree = elements(host) + navigation.flatMap { elements($0) }
                + (host.accessibilityHitTest(center).map { elements($0) } ?? [])
            let buttons = tree.filter { $0.accessibilityRole() == .button }.map {
                Button(label: $0.accessibilityLabel() ?? "", value: $0.accessibilityValue() as? String ?? "")
            }
            result = evaluate(buttons, title: tr(quota.title), reset: pointInTime(reset), pace: tr("Bei gleichmäßigem Verbrauch"))
            if result == .verified { break }
        }
        return result
    }
}
