import SwiftUI
#if JUICEBAR_DIRECT
import Sparkle
#endif

/// Update delivery is independent of payment, provider accounts and usage collection.
@MainActor final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    static let project = URL(string: "https://github.com/Rasalas/juicebar")!
    static let releases = project.appendingPathComponent("releases")
    @Published private(set) var canCheck = false
    @Published private(set) var available = false
    @Published private(set) var error: String?
    #if JUICEBAR_DIRECT
    private var controller: SPUStandardUpdaterController?
    #endif

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Entwicklung" }

    func start() {
        #if JUICEBAR_DIRECT
        guard controller == nil,
              !CommandLine.arguments.contains("--demo"),
              Bundle.main.bundleURL.pathExtension == "app",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller = value
        value.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        do {
            try value.updater.start()
            available = true
        } catch { self.error = error.localizedDescription }
        #endif
    }

    var automaticChecks: Bool {
        get {
            #if JUICEBAR_DIRECT
            return controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if JUICEBAR_DIRECT
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    func check() {
        #if JUICEBAR_DIRECT
        if available { controller?.checkForUpdates(nil); return }
        #endif
        NSWorkspace.shared.open(Self.releases)
    }
}
