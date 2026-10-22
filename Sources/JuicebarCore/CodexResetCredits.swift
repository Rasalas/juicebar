import Foundation

/// One bounded connection shared by quota reads and explicitly requested reset redemptions.
final class CodexControlSession {
    private let client: ProcessClient
    init(configuration: AccountConfiguration) throws {
        var environment: [String: String] = [:]
        if !configuration.profileDirectory.isEmpty {
            environment["CODEX_HOME"] = NSString(string: configuration.profileDirectory).expandingTildeInPath
        }
        client = try ProcessClient(executable: ProcessClient.executable("codex", custom: configuration.executablePath),
                                   arguments: ["app-server", "--stdio"], environment: environment, timeout: 18)
        do {
            _ = try request(1, "initialize", ["clientInfo": ["name": "juicebar", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
            try client.send(["method": "initialized"])
        } catch { client.close(); throw error }
    }
    func close() { client.close() }
    func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
        try Task.checkCancellation()
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        try client.send(object)
        let reply = try client.receive { ($0["id"] as? Int) == id }
        if let error = reply["error"] as? [String: Any] {
            let message = (error["message"] as? String ?? "").lowercased()
            if message.contains("auth") || message.contains("login") || message.contains("sign in") { throw ProviderFailure.authentication }
            throw ProviderFailure.unsupported(tr("Codex unterstützt diese Aktion nicht. CLI-Version und Anmeldung prüfen."))
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw ProviderFailure.invalidData(tr("Codex liefert eine unbekannte Antwort."))
        }
        return result
    }
}

public enum CodexResetOutcome: String, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
}

public struct CodexResetResult: Sendable {
    public let outcome: CodexResetOutcome
    public let snapshot: AccountSnapshot?
    public init(outcome: CodexResetOutcome, snapshot: AccountSnapshot?) {
        self.outcome = outcome; self.snapshot = snapshot
    }
}

/// Separate from the read-only provider. A caller must retain the key until an outcome is known.
public protocol CodexResetRedeeming: Sendable {
    func redeem(configuration: AccountConfiguration, expectedSnapshot: AccountSnapshot,
                creditID: String, idempotencyKey: String) async throws -> CodexResetResult
}

public struct CodexResetCredits: CodexResetRedeeming {
    public init() {}
    public func redeem(configuration: AccountConfiguration, expectedSnapshot: AccountSnapshot,
                       creditID: String, idempotencyKey: String) async throws -> CodexResetResult {
        guard configuration.provider == .codex, expectedSnapshot.configurationID == configuration.id,
              expectedSnapshot.identity != AccountIdentity.fallback(for: configuration),
              !creditID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderFailure.invalidData(tr("Die Reset-Gutschrift konnte nicht zugeordnet werden."))
        }
        let task = Task.detached(priority: .userInitiated) {
            let session = try CodexControlSession(configuration: configuration)
            defer { session.close() }
            let account = try session.request(2, "account/read", ["refreshToken": false])
            let before = try ProviderParsing.codex(session.request(3, "account/rateLimits/read"), configuration: configuration, account: account)
            guard before.identity == expectedSnapshot.identity else {
                throw ProviderFailure.unavailable(tr("Die Codex-Anmeldung hat sich geändert. Kontostand aktualisieren."))
            }
            let reply: [String: Any]
            do {
                // Always identify this exact credit. Never silently consume the next credit.
                reply = try session.request(4, "account/rateLimitResetCredit/consume",
                                            ["creditId": creditID, "idempotencyKey": idempotencyKey])
            } catch ProviderFailure.authentication { throw ProviderFailure.authentication }
            catch let error as ProviderFailure {
                if case .unsupported = error { throw error }
                throw ProviderFailure.unavailable(tr("Einlösung nicht bestätigt. Bitte erneut versuchen."))
            } catch {
                throw ProviderFailure.unavailable(tr("Einlösung nicht bestätigt. Bitte erneut versuchen."))
            }
            guard let raw = reply["outcome"] as? String, let outcome = CodexResetOutcome(rawValue: raw) else {
                throw ProviderFailure.invalidData(tr("Einlösung nicht bestätigt. Bitte erneut versuchen."))
            }
            // A failed follow-up read must not turn a confirmed redemption into a retry of the mutation.
            let fresh = try? ProviderParsing.codex(session.request(5, "account/rateLimits/read"), configuration: configuration, account: account)
            return CodexResetResult(outcome: outcome, snapshot: fresh?.identity == expectedSnapshot.identity ? fresh : nil)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Preview mode never calls an account service.
public struct DemoCodexResetCredits: CodexResetRedeeming {
    public init() {}
    public func redeem(configuration: AccountConfiguration, expectedSnapshot: AccountSnapshot,
                       creditID: String, idempotencyKey: String) async throws -> CodexResetResult {
        var snapshot = expectedSnapshot
        snapshot.observedAt = Date()
        snapshot.benefits.removeAll { $0.id == creditID }
        snapshot.benefitCount = max(0, (snapshot.benefitCount ?? 1) - 1)
        for index in snapshot.windows.indices { snapshot.windows[index].usedPercent = 0 }
        return CodexResetResult(outcome: .reset, snapshot: snapshot)
    }
}
