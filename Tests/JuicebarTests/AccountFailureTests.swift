import XCTest
import SwiftUI
@testable import JuicebarCore
@testable import Juicebar

private struct FailureCredentials: CredentialStore {
    func read(account: String) -> String? { nil }
    func contains(account: String) -> Bool { false }
    func save(_ secret: String, account: String) {}
    func remove(account: String) {}
}

private actor FailureProvider: UsageProvider {
    let error: ProviderFailure
    private(set) var calls = 0
    init(_ error: ProviderFailure) { self.error = error }
    func read(configuration: AccountConfiguration, includeHistory: Bool) throws -> AccountSnapshot {
        calls += 1
        throw error
    }
}

actor HeldFailureProvider: UsageProvider {
    private var continuation: CheckedContinuation<AccountSnapshot, Error>?
    private(set) var calls = 0
    func read(configuration: AccountConfiguration, includeHistory: Bool) async throws -> AccountSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<AccountSnapshot, Error>) { continuation?.resume(with: result); continuation = nil }
}

private final class FailureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class AccountFailureTests: XCTestCase {
    private func fixture(_ provider: any UsageProvider, worker: DispatchQueue? = nil, kind: ProviderKind = .codex) async throws -> (AppStore, AccountConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-failures-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfiguration(id: "fixture", provider: kind, executablePath: "/fixture/never-run")
        let db = try HistoryDatabase(path: directory.appendingPathComponent("usage.sqlite").path)
        try db.write([account], key: "accounts")
        try db.save(AccountSnapshot(configurationID: account.id, identity: "fixture", source: "fixture"))
        let store = AppStore(directory: directory, credentials: FailureCredentials(), registry: ProviderRegistry(overrides: [kind: provider]), notifications: NotificationFixture(), persistence: AppPersistence(directory: directory, demo: false, credentials: FailureCredentials(), workerTarget: worker), activityReader: { _, _, _ in }, activityCatalogRefresh: {})
        await store.waitUntilReady()
        addTeardownBlock { await store.shutDown() }
        return (store, account)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let reached = await predicate()
        XCTAssertTrue(reached)
        if !reached { throw ProviderFailure.timedOut }
    }

    func testRefreshKeepsFailureTypeAndLastValue() async throws {
        let (store, account) = try await fixture(FailureProvider(.network))
        let previous = store.snapshots[account.id]
        store.refresh(force: true)
        try await waitUntil { !store.isRefreshing }
        let failure = try XCTUnwrap(store.failures[account.id])
        XCTAssertEqual(failure, .provider(.network))
        XCTAssertEqual(failure.actions(for: account), [.retry, .configure])
        XCTAssertEqual(store.snapshots[account.id], previous)
    }
    func testClassificationUsesTypedCasesEvenWhenMessagesMatchAnotherFailure() {
        let account = AccountConfiguration(provider: .codex)
        let cases: [ProviderFailure] = [.authentication, .network, .timedOut, .rateLimited(120), .needsSetup("fixture"), .missingExecutable("fixture"), .invalidData("fixture"), .unsupported("fixture"), .unavailable("fixture")]
        for error in cases {
            let failure = AccountFailure(error)
            XCTAssertEqual(failure, .provider(error))
            XCTAssertEqual(failure.message, error.localizedDescription)
        }
        for language in ["en", "de"] {
            let message = Localization.text("Anmeldung fehlt oder ist abgelaufen. Beim Anbieter erneut anmelden.", language: language)
            XCTAssertEqual(AccountFailure(ProviderFailure.unavailable(message)).actions(for: account), [.retry, .configure])
            XCTAssertEqual(AccountFailure(ProviderFailure.invalidData(message)).actions(for: account), [.configure, .providerPage])
        }
        let unknown = AccountFailure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret=fixture-private-payload"]))
        XCTAssertEqual(unknown, .unknown)
        XCTAssertFalse(unknown.message.contains("fixture-private-payload"))
        XCTAssertEqual(unknown.actions(for: account), [.retry, .configure])
        XCTAssertEqual(AccountFailure(CredentialRecoveryFailure()), .credentialRecovery)
    }

    func testRealTransportErrorsRetainClassificationWithoutExposingResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (status, expected) in [(401, ProviderFailure.authentication), (403, .unsupported(tr("Der Anbieter verweigert den Zugriff. Berechtigungen und aktives Abonnement prüfen."))), (429, .rateLimited(120)), (500, .network)] {
            do {
                _ = try await HTTPTransport.get(URL(string: "https://fixture.invalid/\(status)")!, headers: [:], session: session)
                XCTFail("Expected a transport failure")
            } catch { XCTAssertEqual(AccountFailure(error), .provider(expected)) }
        }
        XCTAssertThrowsError(try ProcessClient.executable("fixture", custom: "/fixture/never-an-executable")) {
            XCTAssertEqual(AccountFailure($0).actions(for: AccountConfiguration(provider: .codex)), [.configure])
        }
        XCTAssertThrowsError(try HTTPTransport.decode(Data("[]".utf8))) {
            guard case .provider(.invalidData) = AccountFailure($0) else { return XCTFail("Must preserve invalid data classification") }
        }
    }

    func testActionsForProviderContextsAndConfiguredLoginCommands() throws {
        for provider in ProviderKind.allCases {
            let account = AccountConfiguration(provider: provider, executablePath: "/fixture/My 'CLI'", profileDirectory: "/fixture/profile $literal")
            let actions = AccountFailure.provider(.authentication).actions(for: account)
            if provider == .codex || provider == .claude {
                let command = try XCTUnwrap(CLISetupHelp.loginCommand(for: account))
                XCTAssertTrue(command.contains("'\"'\"'"))
                XCTAssertTrue(command.contains("'/fixture/profile $literal'"))
                XCTAssertEqual(actions, [.copyLogin(command), .retry, .configure])
            } else { XCTAssertEqual(actions, [.configure, .providerPage]) }
            for error in [ProviderFailure.network, .timedOut, .unavailable("fixture")] {
                XCTAssertEqual(AccountFailure(error).actions(for: account), [.retry, .configure])
            }
            for error in [ProviderFailure.missingExecutable("fixture"), .needsSetup("fixture")] {
                XCTAssertEqual(AccountFailure(error).actions(for: account), [.configure])
            }
            for error in [ProviderFailure.invalidData("fixture"), .unsupported("fixture")] {
                XCTAssertEqual(AccountFailure(error).actions(for: account), [.configure, .providerPage])
            }
            XCTAssertEqual(AccountFailure.provider(.rateLimited(120)).actions(for: account), [.retry])
            XCTAssertEqual(AccountFailure.credentialRecovery.actions(for: account), [.restoreCredentials])
        }
    }

    func testManualRetryUsesExistingSchedulerAndBusyPauseAndMutationGuards() async throws {
        let provider = HeldFailureProvider()
        defer { Task { await provider.finish(.failure(CancellationError())) } }
        let worker = DispatchQueue(label: "fixture.account-mutation")
        let (store, account) = try await fixture(provider, worker: worker)
        store.failures[account.id] = .provider(.timedOut)
        XCTAssertEqual(store.failureRecoveryState(for: account), .ready)
        await store.retryAccountFailure(for: account)
        try await waitUntil { store.isRefreshing }
        XCTAssertEqual(store.failureRecoveryState(for: account), .running)
        await store.retryAccountFailure(for: account)
        // The scheduler task may not have entered the provider until this actor hop.
        try await waitUntil { await provider.calls > 0 }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        await provider.finish(.failure(ProviderFailure.network))
        try await waitUntil { !store.isRefreshing }
        XCTAssertEqual(store.failures[account.id], .provider(.network))
        XCTAssertEqual(store.failureRecoveryState(for: account), .ready, "Manual retry may bypass ordinary backoff")
        store.isPaused = true
        XCTAssertEqual(store.failureRecoveryState(for: account), .unavailable)
        await store.retryAccountFailure(for: account)
        var edited = account; edited.label = "Edited"
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        worker.async { _ = release.wait(timeout: .now() + 4) }
        let mutation = Task { try await store.saveAccount(edited, secret: "") }
        try await waitUntil { store.pendingStorageOperations > 0 }
        XCTAssertEqual(store.failureRecoveryState(for: account), .running)
        await store.retryAccountFailure(for: account)
        release.signal()
        try await mutation.value
        XCTAssertEqual(store.failureRecoveryState(for: account), .unavailable, "A stale view cannot retry the edited account")
        let finalCalls = await provider.calls
        XCTAssertEqual(finalCalls, 1)
    }

    func testConfigurationFailuresDoNotIssueRequestsThroughRetryHelper() async throws {
        let provider = FailureProvider(.network)
        let (store, account) = try await fixture(provider)
        for error in [ProviderFailure.missingExecutable("fixture"), .needsSetup("fixture"), .invalidData("fixture"), .unsupported("fixture")] {
            store.failures[account.id] = AccountFailure(error)
            await store.retryAccountFailure(for: account)
            XCTAssertFalse(store.isRefreshing)
        }
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        let (apiStore, apiAccount) = try await fixture(provider, kind: .openaiAPI)
        apiStore.failures[apiAccount.id] = .provider(.authentication)
        await apiStore.retryAccountFailure(for: apiAccount)
        XCTAssertFalse(apiStore.isRefreshing)
        let apiCalls = await provider.calls
        XCTAssertEqual(apiCalls, 0, "API authentication needs configuration, not a blind retry")
    }

    func testRateLimitBlocksManualAndGlobalForceUntilPolicyDeadline() async throws {
        let provider = FailureProvider(.rateLimited(120))
        let (store, account) = try await fixture(provider)
        store.refresh(force: true)
        try await waitUntil { !store.isRefreshing }
        guard case .waiting(let until) = store.failureRecoveryState(for: account) else { return XCTFail("Missing cooldown") }
        XCTAssertGreaterThan(until.timeIntervalSinceNow, 115)
        XCTAssertEqual(store.failureRecoveryState(for: account, at: until.addingTimeInterval(-0.001)), .waiting(until: until))
        XCTAssertEqual(store.failureRecoveryState(for: account, at: until), .ready)
        await store.retryAccountFailure(for: account)
        store.refresh(force: true)
        XCTAssertFalse(store.isRefreshing)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.failures[account.id], .provider(.rateLimited(120)))
    }

    func testMetadataEditsPreserveProviderCooldownAndCredentialChangeAllowsRetry() async throws {
        let provider = FailureProvider(.rateLimited(120))
        let (store, account) = try await fixture(provider)
        store.refresh(force: true)
        try await waitUntil { !store.isRefreshing }
        guard case .waiting(let until) = store.failureRecoveryState(for: account) else { return XCTFail("Missing cooldown") }
        var edited = account
        for edit in ["label", "budget", "disable", "enable"] {
            switch edit {
            case "label": edited.label = "Renamed"
            case "budget": edited.monthlyBudget = 100
            case "disable": edited.enabled = false
            default: edited.enabled = true
            }
            try await store.saveAccount(edited, secret: "")
            store.refresh(force: true)
            try await waitUntil { !store.isRefreshing }
            let calls = await provider.calls
            XCTAssertEqual(calls, 1, edit)
            XCTAssertEqual(store.failures[account.id], .provider(.rateLimited(120)))
            if edited.enabled { XCTAssertEqual(store.failureRecoveryState(for: edited), .waiting(until: until)) }
        }
        try await store.saveAccount(edited, secret: "synthetic-replacement-key")
        try await waitUntil { await provider.calls == 2 && !store.isRefreshing }
    }

    func testSuccessfulRetryPublishesFreshValueAndClearsFailure() async throws {
        let provider = HeldFailureProvider()
        defer { Task { await provider.finish(.failure(CancellationError())) } }
        let (store, account) = try await fixture(provider)
        store.failures[account.id] = .provider(.network)
        store.resetAccountsAwaitingRefresh.insert(account.id)
        await store.retryAccountFailure(for: account)
        try await waitUntil { await provider.calls > 0 }
        let snapshot = AccountSnapshot(configurationID: account.id, identity: "fixture", source: "fresh fixture")
        await provider.finish(.success(snapshot))
        try await waitUntil { !store.isRefreshing }
        XCTAssertNil(store.failures[account.id])
        XCTAssertEqual(store.snapshots[account.id]?.source, "fresh fixture")
        XCTAssertFalse(store.resetAccountsAwaitingRefresh.contains(account.id))
    }

    func testOffscreenFailureStates() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if let language = ProcessInfo.processInfo.environment["JUICEBAR_FAILURE_RENDER_LANGUAGE"] {
            var arguments = previous; arguments["appLanguage"] = language
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        let provider = FailureProvider(.rateLimited(120))
        let (store, original) = try await fixture(provider)
        var account = original
        account.executablePath = "/fixture/Tools/My CLI 'quoted'"
        account.profileDirectory = "/fixture/Profile $literal"
        try await store.saveAccount(account, secret: "")
        try await waitUntil { !store.isRefreshing }
        let (plainStore, _) = try await fixture(FailureProvider(.network))
        try await plainStore.saveAccount(account, secret: "")
        try await waitUntil { !plainStore.isRefreshing }
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["JUICEBAR_FAILURE_RENDER_DIR"] { directory = URL(fileURLWithPath: path) }
        else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("failure-render-\(UUID())")
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain the real policy cooldown for the rate-limit state; other states use fixture errors.
        let states: [(String, AccountFailure)] = [("cooldown", .provider(.rateLimited(120))), ("login", .provider(.authentication)), ("network", .provider(.network)), ("busy", .provider(.network)), ("recovery", .credentialRecovery), ("unsupported", .provider(.unsupported("Fixture: this account does not support quota reads.")))]
        for dark in [false, true] {
            for width: CGFloat in [344, 680] {
                for (name, failure) in states {
                    let renderedStore = name == "cooldown" ? store : plainStore
                    renderedStore.failures[account.id] = failure
                    if name == "busy" { renderedStore.refreshingAccountIDs.insert(account.id) }
                    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                    NSApp.appearance = appearance
                    let view = AccountFailureView(store: renderedStore, account: account, failure: failure)
                        .padding(12).frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: view)
                    let size = host.fittingSize
                    XCTAssertEqual(size.width, width, accuracy: 1)
                    XCTAssertGreaterThan(size.height, 70)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    window.close()
                    renderedStore.refreshingAccountIDs.remove(account.id)
                }
            }
        }
    }

    func testLateErrorsAfterEditRemovalAndShutdownAreDiscarded() async throws {
        for action in ["edit", "remove", "shutdown"] {
            let provider = HeldFailureProvider()
            defer { Task { await provider.finish(.failure(CancellationError())) } }
            let (store, account) = try await fixture(provider)
            let original = store.snapshots[account.id]
            store.refresh(force: true)
            try await waitUntil { await provider.calls > 0 }
            store.isPaused = true
            switch action {
            case "edit":
                var edited = account; edited.label = "Edited"
                try await store.saveAccount(edited, secret: "")
            case "remove": await store.removeAccount(account)
            default: store.stop()
            }
            await provider.finish(.failure(ProviderFailure.authentication))
            await store.shutDown()
            XCTAssertNil(store.failures[account.id])
            if action != "remove" { XCTAssertEqual(store.snapshots[account.id], original) }
        }
    }

}
