import Foundation
import CryptoKit

public struct CatalogDocument: Codable, Sendable {
    public struct Rate: Codable, Sendable {
        public var input: Double; public var output: Double; public var read: Double
        public var write: Double; public var hour: Double; public var longContext: Double?
        public var source: URL; public var verifiedOn: String
    }
    public var schema: Int
    public var revision: Int
    public var verifiedOn: String
    public var aliases: [ModelAliases.Alias]
    public var rates: [String: Rate]
    public func resolve(model: String, provider: String) -> ModelAliases.Alias? {
        aliases.first { $0.providers.contains(provider.lowercased()) && $0.names.contains(model.lowercased()) }
    }
    func validate() throws {
        func date(_ value: String) -> Bool {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            return value.count == 10 && formatter.date(from: value).map { formatter.string(from: $0) == value } == true
        }
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 200 && value == value.lowercased() && !value.contains("|") && !value.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        func source(_ url: URL) -> Bool { url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil }
        guard schema == 1, revision > 0, date(verifiedOn), !rates.isEmpty, rates.count <= 5000, aliases.count <= 2000 else { throw CatalogError.schema }
        for (name, rate) in rates {
            guard identifier(name), [rate.input, rate.output, rate.read, rate.write, rate.hour].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }),
                  rate.longContext.map({ $0.isFinite && $0 > 0 }) ?? true, source(rate.source), date(rate.verifiedOn) else { throw CatalogError.schema }
        }
        var scoped = Set<String>()
        for alias in aliases {
            guard rates[alias.canonicalModel] != nil, !alias.displayName.isEmpty, alias.displayName.count <= 200,
                  !alias.names.isEmpty, !alias.providers.isEmpty, alias.names.count <= 100, alias.providers.count <= 100,
                  source(alias.source), date(alias.verifiedOn) else { throw CatalogError.schema }
            for provider in alias.providers {
                for name in alias.names {
                    guard identifier(provider), identifier(name), scoped.insert("\(provider)|\(name)").inserted else { throw CatalogError.schema }
                }
            }
        }
    }
}

public enum CatalogError: Error { case signature, schema, oversized, rollback, network }
struct CatalogEnvelope: Codable { var payload: Data; var signature: Data }

/// An immutable snapshot per price calculation. A failed update leaves the last valid data intact.
public final class ModelCatalog: @unchecked Sendable {
    public static let shared = ModelCatalog()
    public static let maximumBytes = 1_500_000
    private let lock = NSLock()
    private var document: CatalogDocument
    private let publicKey: Data
    private var directory: URL?
    private var refreshing = false
    private var nextCheck = Date.distantPast
    public var snapshot: CatalogDocument { lock.withLock { document } }
    public init() {
        let url = Bundle.module.url(forResource: "model-catalog", withExtension: "json")!
        document = try! JSONDecoder().decode(CatalogDocument.self, from: Data(contentsOf: url))
        publicKey = Data(base64Encoded: (try! String(contentsOf: Bundle.module.url(forResource: "catalog-public-key", withExtension: "txt")!, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
    }
    // Internal injection keeps security tests independent of the release signing key.
    init(document: CatalogDocument, publicKey: Data) { self.document = document; self.publicKey = publicKey }
    public func configure(directory: URL) {
        lock.withLock {
            guard self.directory == nil else { return }
            self.directory = directory
            for name in ["model-catalog.signed.json", "model-catalog.previous.json"] {
                let url = directory.appendingPathComponent(name)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
                      let data = try? Data(contentsOf: url), let cached = try? Self.verify(data, publicKey: publicKey), cached.revision >= document.revision else { continue }
                document = cached
            }
        }
    }
    static func verify(_ data: Data, publicKey: Data) throws -> CatalogDocument {
        guard data.count <= maximumBytes else { throw CatalogError.oversized }
        let envelope = try JSONDecoder().decode(CatalogEnvelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else { throw CatalogError.signature }
        let doc = try JSONDecoder().decode(CatalogDocument.self, from: envelope.payload)
        try doc.validate()
        return doc
    }
    @discardableResult func install(_ data: Data) throws -> Bool {
        let incoming = try Self.verify(data, publicKey: publicKey)
        return try lock.withLock {
            guard incoming.revision >= document.revision else { throw CatalogError.rollback }
            guard incoming.revision > document.revision else { return false }
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let current = directory.appendingPathComponent("model-catalog.signed.json")
                // Retain only previously verified bytes, never a damaged file left on disk.
                if let old = try? Data(contentsOf: current), let previous = try? Self.verify(old, publicKey: publicKey), previous.revision == document.revision {
                    try old.write(to: directory.appendingPathComponent("model-catalog.previous.json"), options: .atomic)
                }
                try data.write(to: current, options: .atomic)
            }
            document = incoming
            return true
        }
    }
    /// At most once a day, no cookies, credentials, telemetry or executable content.
    public func refreshIfNeeded(now: Date = Date()) async -> Bool {
        let shouldRun = lock.withLock {
            guard !refreshing, now >= nextCheck else { return false }
            refreshing = true; nextCheck = now.addingTimeInterval(86400); return true
        }
        guard shouldRun else { return false }
        defer { lock.withLock { refreshing = false } }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: URL(string: "https://rasalas.github.io/juicebar/catalog/model-catalog.signed.json")!)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https", http.expectedContentLength <= Self.maximumBytes else { throw CatalogError.network }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); data.append(byte)
                guard data.count <= Self.maximumBytes else { throw CatalogError.oversized }
            }
            return try install(data)
        } catch { return false }
    }
}
