import Foundation
import Security
import LocalAuthentication

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
    public static func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; attributes.forEach { new[$0] = $1 }
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw ProviderFailure.unavailable(tr("Schlüssel konnte nicht im Schlüsselbund gespeichert werden.")) }
        } else if status != errSecSuccess { throw ProviderFailure.unavailable(tr("Schlüsselbund ist nicht verfügbar.")) }
    }
    public static func remove(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

public enum HTTPTransport {
    public static func get(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("Juicebar/0.1.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProviderFailure.network }
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
            guard response.expectedContentLength <= 2_000_000 else { throw ProviderFailure.invalidData(tr("Die Anbieterantwort ist zu groß.")) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 2_000_000 else { throw ProviderFailure.invalidData(tr("Die Anbieterantwort ist zu groß.")) }
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderFailure.invalidData(tr("Unbekanntes Antwortformat. Adapter aktualisieren.")) }
            return object
        } catch let error as ProviderFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProviderFailure.network }
    }
}

public enum JSONValue {
    public static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue; return result.isFinite ? result : nil
    }
    public static func amount(_ value: Any?) -> Double? { number(value) ?? (value as? String).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    public static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    public static func title(duration: TimeInterval?, fallback: String) -> String {
        guard let duration, duration > 0 else { return fallback }
        if duration == 604800 { return tr("Woche") }
        if duration >= 86400 { return tr("{0} Tage", Int(duration / 86400)) }
        if duration >= 3600 { return tr("{0} Stunden", Int(duration / 3600)) }
        return tr("{0} Minuten", Int(duration / 60))
    }
}
