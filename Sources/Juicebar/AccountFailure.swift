import Foundation
import JuicebarCore

/// Retains provider meaning and its safe message. Unknown errors never expose arbitrary payloads.
/// Recovery choices depend on typed cases and account configuration, never translated text.
enum AccountFailure: Equatable {
    case provider(ProviderFailure)
    case credentialRecovery
    case unknown

    init(_ error: Error) {
        if error is CredentialRecoveryFailure { self = .credentialRecovery }
        else if let error = error as? ProviderFailure { self = .provider(error) }
        else { self = .unknown }
    }

    var message: String {
        switch self {
        case .provider(let error): return error.localizedDescription
        case .credentialRecovery: return CredentialRecoveryFailure().localizedDescription
        case .unknown: return tr("Der Kontostand konnte nicht abgerufen werden. Der letzte Stand bleibt sichtbar. Bitte erneut versuchen oder die Kontoeinstellungen prüfen.")
        }
    }

    enum Action: Equatable {
        case retry, restoreCredentials, copyLogin(String), configure, providerPage
    }

    @MainActor func actions(for account: AccountConfiguration) -> [Action] {
        switch self {
        case .credentialRecovery: return [.restoreCredentials]
        case .provider(.authentication):
            if let command = CLISetupHelp.loginCommand(for: account) {
                return [.copyLogin(command), .retry, .configure]
            }
            return [.configure, .providerPage]
        case .provider(.missingExecutable), .provider(.needsSetup): return [.configure]
        case .provider(.unsupported), .provider(.invalidData): return [.configure, .providerPage]
        case .provider(.rateLimited): return [.retry]
        case .provider(.network), .provider(.timedOut), .provider(.unavailable), .unknown:
            return [.retry, .configure]
        }
    }
}

/// Shared by dashboard and tray. The store also enforces this state when an action is invoked.
enum AccountFailureRecoveryState: Equatable {
    case ready, running, waiting(until: Date), unavailable
    var canRetry: Bool { self == .ready }
    var isRunning: Bool { self == .running }
}
