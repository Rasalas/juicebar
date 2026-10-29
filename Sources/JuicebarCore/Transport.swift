import Foundation
import Security
import LocalAuthentication

/// Mutations either succeed completely or throw without changing the saved credential.
public protocol CredentialStore {
    func read(account: String) throws -> String?
    func contains(account: String) -> Bool
    func save(_ secret: String, account: String) throws
    func remove(account: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public init() {}
    public func read(account: String) throws -> String? { try SecretStore.readForMutation(account: account) }
    public func contains(account: String) -> Bool { SecretStore.contains(account: account) }
    public func save(_ secret: String, account: String) throws { try SecretStore.save(secret, account: account) }
    public func remove(account: String) throws { try SecretStore.remove(account: account) }
}

public enum SecretStore {
    private static let service = "app.juicebar.credentials"
    public static func read(account: String) -> String? { read(service: service, account: account) }
    public static func read(service: String, account: String? = nil) -> String? {
        // LAContext alone does not suppress legacy login-keychain ACL dialogs.
        // This app never asks Security.framework to interact with the user.
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecUseAuthenticationContext as String: context]
        if let account { query[kSecAttrAccount as String] = account }
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Checks attributes only, so no item data and no access prompt is involved.
    public static func contains(account: String) -> Bool {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                    kSecUseAuthenticationContext as String: context]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    public static func save(_ secret: String, account: String) throws {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecUseAuthenticationContext as String: context]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; attributes.forEach { new[$0] = $1 }
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw ProviderFailure.unavailable(tr("Schlüssel konnte nicht im Schlüsselbund gespeichert werden.")) }
        } else if status != errSecSuccess { throw ProviderFailure.unavailable(tr("Schlüsselbund ist nicht verfügbar.")) }
    }
    /// A failed read must not be mistaken for an absent key during compensation.
    public static func readForMutation(account: String) throws -> String? {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw ProviderFailure.unavailable(tr("Schlüsselbund ist nicht verfügbar."))
        }
        return secret
    }
    public static func remove(account: String) throws {
        SecKeychainSetUserInteractionAllowed(false)
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecUseAuthenticationContext as String: context]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderFailure.unavailable(tr("Schlüssel konnte nicht aus dem Schlüsselbund entfernt werden."))
        }
    }
}

public enum HTTPTransport {
    static let maximumBytes = 2_000_000
    // Shared so connections and TLS sessions are reused between polls.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()
    public static func get(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        try await get(url, headers: headers, session: session)
    }
    // Session injection keeps transport tests local and credential-free.
    static func get(_ url: URL, headers: [String: String], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("Juicebar/0.1.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        do {
            let body = BoundedHTTPBody()
            let data = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { body.start(request, session: session, continuation: $0) }
            } onCancel: { body.cancel() }
            try Task.checkCancellation()
            return try decode(data)
        } catch let error as ProviderFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled && Task.isCancelled { throw CancellationError() }
        catch { throw ProviderFailure.network }
    }
    fileprivate static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ProviderFailure.network }
        // Reject error responses at the headers; never retain their potentially unbounded bodies.
        switch response.statusCode {
        case 200..<300: break
        case 401: throw ProviderFailure.authentication
        case 403: throw ProviderFailure.unsupported(tr("Der Anbieter verweigert den Zugriff. Berechtigungen und aktives Abonnement prüfen."))
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let delay = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSinceNow ?? 300
            throw ProviderFailure.rateLimited(max(60, min(delay, 86400)))
        case 404: throw ProviderFailure.unsupported(tr("Diese Datenquelle ist für das Konto nicht verfügbar."))
        default: throw ProviderFailure.network
        }
        guard response.expectedContentLength <= maximumBytes else { throw oversized }
    }
    fileprivate static var oversized: ProviderFailure { .invalidData(tr("Die Anbieterantwort ist zu groß.")) }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw ProviderFailure.invalidData(tr("Die Anbieterantwort ist zu groß.")) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure.invalidData(tr("Unbekanntes Antwortformat. Adapter aktualisieren.")) }
        return object
    }
}

/// One accumulator per request. The task delegate bounds received chunks before copying them.
/// The lock coordinates delegate callbacks with cancellation, including cancellation before start.
private final class BoundedHTTPBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var completed = false
    private var validated = false
    private var data = Data()

    func start(_ request: URLRequest, session: URLSession, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        lock.unlock()
        task.resume()
    }
    func cancel() { finish(.failure(CancellationError())) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try HTTPTransport.validate(response)
            lock.lock()
            validated = true
            let active = !completed
            lock.unlock()
            completionHandler(active ? .allow : .cancel)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard chunk.count <= HTTPTransport.maximumBytes - data.count else {
            lock.unlock()
            finish(.failure(HTTPTransport.oversized))
            return
        }
        data.append(chunk)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Data, Error> = error.map { .failure($0) } ?? (validated ? .success(data) : .failure(ProviderFailure.network))
        lock.unlock()
        finish(result)
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation, task = self.task
        self.continuation = nil; self.task = nil; data = Data()
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }
}

public enum JSONValue {
    public static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue; return result.isFinite ? result : nil
    }
    public static func amount(_ value: Any?) -> Double? { number(value) ?? (value as? String).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    public static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds >= 1 { return QuotaNumbers.date(Date(timeIntervalSince1970: seconds)) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return QuotaNumbers.date(date) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return QuotaNumbers.date(formatter.date(from: text))
    }
    public static func title(duration: TimeInterval?, fallback: String) -> String {
        guard let duration = QuotaNumbers.duration(duration) else { return fallback }
        if duration == 604800 { return tr("Woche") }
        if duration >= 86400 { return tr("{0} Tage", Int(duration / 86400)) }
        if duration >= 3600 { return tr("{0} Stunden", Int(duration / 3600)) }
        return tr("{0} Minuten", Int(duration / 60))
    }
}
