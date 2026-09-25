import XCTest
import CryptoKit
@testable import JuicebarCore

final class ModelCatalogTests: XCTestCase {
    private func envelope(_ document: CatalogDocument, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let payload = try JSONEncoder().encode(document)
        return try JSONEncoder().encode(CatalogEnvelope(payload: payload, signature: key.signature(for: payload)))
    }
    func testPublishedEnvelopeMatchesBundledBaselineAndKey() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let key = try String(contentsOf: root.appendingPathComponent("Sources/JuicebarCore/Resources/catalog-public-key.txt"), encoding: .utf8)
        let data = try Data(contentsOf: root.appendingPathComponent("site/catalog/model-catalog.signed.json"))
        let document = try ModelCatalog.verify(data, publicKey: XCTUnwrap(Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines))))
        XCTAssertEqual(document.revision, ModelCatalog().snapshot.revision)
        XCTAssertEqual(document.rates.count, ModelCatalog().snapshot.rates.count)
    }
    func testSignatureSchemaLimitsAndRollback() throws {
        let key = Curve25519.Signing.PrivateKey()
        var doc = ModelCatalog().snapshot
        try doc.validate()
        let store = ModelCatalog(document: doc, publicKey: key.publicKey.rawRepresentation)
        doc.revision += 1
        let valid = try envelope(doc, key: key)
        XCTAssertTrue(try store.install(valid))
        XCTAssertFalse(try store.install(valid))
        var tampered = try JSONDecoder().decode(CatalogEnvelope.self, from: valid)
        tampered.payload.append(32)
        XCTAssertThrowsError(try store.install(JSONEncoder().encode(tampered)))
        XCTAssertThrowsError(try ModelCatalog.verify(valid, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        doc.revision -= 1
        XCTAssertThrowsError(try store.install(envelope(doc, key: key)))
        doc.revision += 2; doc.schema = 99
        XCTAssertThrowsError(try store.install(envelope(doc, key: key)))
        doc.schema = 1; doc.rates["gpt-6-astra"]?.input = -1
        XCTAssertThrowsError(try store.install(envelope(doc, key: key)))
        XCTAssertThrowsError(try ModelCatalog.verify(Data(repeating: 0, count: ModelCatalog.maximumBytes + 1), publicKey: key.publicKey.rawRepresentation))
        XCTAssertEqual(store.snapshot.revision, 2)
    }
    func testCacheSurvivesRestartAndDamagedUpdateFallsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Curve25519.Signing.PrivateKey(), base = ModelCatalog().snapshot
        func store() -> ModelCatalog { let s = ModelCatalog(document: base, publicKey: key.publicKey.rawRepresentation); s.configure(directory: directory); return s }
        let first = store()
        var doc = base; doc.revision = 2
        XCTAssertTrue(try first.install(envelope(doc, key: key)))
        doc.revision = 3
        XCTAssertTrue(try first.install(envelope(doc, key: key)))
        XCTAssertEqual(store().snapshot.revision, 3)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("model-catalog.signed.json"))
        XCTAssertEqual(store().snapshot.revision, 2)
        try Data("damaged".utf8).write(to: directory.appendingPathComponent("model-catalog.previous.json"))
        XCTAssertEqual(store().snapshot.revision, 1)
    }
    func testAliasCollisionAndInvalidProvenanceAreRejected() throws {
        var doc = ModelCatalog().snapshot
        doc.aliases.append(doc.aliases[0])
        XCTAssertThrowsError(try doc.validate())
        doc = ModelCatalog().snapshot; doc.rates["gpt-6-astra"]?.source = URL(string: "http://example.org")!
        XCTAssertThrowsError(try doc.validate())
        doc = ModelCatalog().snapshot; doc.verifiedOn = "2026-02-30"
        XCTAssertThrowsError(try doc.validate())
    }
    func testTranslationsPreserveArgumentsAndGermanFallback() throws {
        XCTAssertEqual(Localization.text("Soll {0} %", arguments: ["34"], language: "en"), "Target 34%")
        XCTAssertEqual(Localization.text("Soll {0} %", arguments: ["34"], language: "de"), "Soll 34 %")
        XCTAssertEqual(Localization.text("{0}: {1} % verbraucht.", arguments: ["{1}", "50"], language: "en"), "{1}: 50% used.")
        let regex = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ s: String) -> [String] { regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted() }
        for (key, translated) in Localization.english { XCTAssertEqual(placeholders(key), placeholders(translated), key) }
    }
}
