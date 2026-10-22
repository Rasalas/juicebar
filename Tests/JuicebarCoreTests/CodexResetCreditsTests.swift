import XCTest
@testable import JuicebarCore

final class CodexResetCreditsTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let configuration: AccountConfiguration
        let snapshot: AccountSnapshot
        func requests() throws -> [[String: Any]] {
            let path = directory.appendingPathComponent("requests.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
    }
    private func fixture(outcome: String = "reset", login: String = "fixture@example.invalid",
                         postReadFails: Bool = false, unknownResponse: Bool = false, disconnectOnConsume: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("juicebar-reset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let before: [String: Any] = [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 90, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]],
            "rateLimitResetCredits": ["availableCount": 2, "credits": [["id": "credit-1", "status": "available"], ["id": "credit-2", "status": "available"]]]
        ]
        let after: [String: Any] = [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(18000).timeIntervalSince1970]],
            "rateLimitResetCredits": ["availableCount": 1, "credits": [["id": "credit-2", "status": "available"]]]
        ]
        let account: [String: Any] = ["account": ["type": "chatgpt", "email": login, "planType": "pro"]]
        let data: [String: Any] = ["before": before, "after": after, "account": account, "outcome": outcome,
                                   "postReadFails": postReadFails, "unknownResponse": unknownResponse, "disconnectOnConsume": disconnectOnConsume]
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("fixture.json"))
        let script = directory.appendingPathComponent("codex-fixture")
        try """
        #!/usr/bin/python3
        import json,os,sys
        from pathlib import Path
        root=Path(os.environ['CODEX_HOME'])
        fixture=json.loads((root/'fixture.json').read_text())
        consumed=False
        for line in sys.stdin:
            request=json.loads(line)
            with (root/'requests.jsonl').open('a') as log:
                log.write(json.dumps(request)+'\\n')
            method=request['method']
            if 'id' not in request: continue
            if method=='initialize': result={}
            elif method=='account/read': result=fixture['account']
            elif method=='account/rateLimits/read':
                if consumed and fixture['postReadFails']: sys.exit(0)
                result=fixture['after'] if consumed else fixture['before']
            elif method=='account/rateLimitResetCredit/consume':
                consumed=True
                if fixture['disconnectOnConsume']: sys.exit(0)
                result={} if fixture['unknownResponse'] else {'outcome':fixture['outcome']}
            else: raise RuntimeError('Unexpected request')
            print(json.dumps({'id':request['id'],'result':result}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let configuration = AccountConfiguration(id: "fixture", provider: .codex, executablePath: script.path, profileDirectory: directory.path)
        let snapshot = try ProviderParsing.codex(before, configuration: configuration,
                                                account: ["account": ["email": "fixture@example.invalid"]])
        return Fixture(directory: directory, configuration: configuration, snapshot: snapshot)
    }

    func testEveryDocumentedOutcomeReadsFreshLimitsAndIdentifiesTheExactCredit() async throws {
        for raw in ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"] {
            let f = try fixture(outcome: raw)
            let result = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: f.snapshot,
                                                            creditID: "credit-1", idempotencyKey: "logical-attempt")
            XCTAssertEqual(result.outcome.rawValue, raw)
            XCTAssertEqual(result.snapshot?.benefitCount, 1)
            XCTAssertEqual(result.snapshot?.windows.first?.usedPercent, 0)
            let requests = try f.requests()
            XCTAssertEqual(requests.compactMap { $0["method"] as? String },
                           ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/rateLimitResetCredit/consume", "account/rateLimits/read"])
            let params = try XCTUnwrap(requests[4]["params"] as? [String: String])
            XCTAssertEqual(params, ["creditId": "credit-1", "idempotencyKey": "logical-attempt"])
        }
    }
    func testChangedLoginStopsBeforeTheMutatingRequest() async throws {
        let f = try fixture(login: "other@example.invalid")
        do {
            _ = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: f.snapshot,
                                                    creditID: "credit-1", idempotencyKey: "attempt")
            XCTFail("A different login must not redeem")
        } catch { XCTAssertTrue(error.localizedDescription.contains(tr("Die Codex-Anmeldung hat sich geändert. Kontostand aktualisieren."))) }
        XCTAssertFalse(try f.requests().contains { $0["method"] as? String == "account/rateLimitResetCredit/consume" })
    }
    func testAConfirmedOutcomeSurvivesFailedFollowupReadWithoutASecondConsume() async throws {
        let f = try fixture(postReadFails: true)
        let result = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: f.snapshot,
                                                        creditID: "credit-1", idempotencyKey: "attempt")
        XCTAssertEqual(result.outcome, .reset)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(try f.requests().filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }.count, 1)
    }
    func testUnknownOutcomeIsNotReportedAsSuccess() async throws {
        let f = try fixture(unknownResponse: true)
        do {
            _ = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: f.snapshot,
                                                    creditID: "credit-1", idempotencyKey: "attempt")
            XCTFail("An unknown outcome needs an idempotent retry")
        } catch { XCTAssertTrue(error.localizedDescription.contains(tr("Einlösung nicht bestätigt. Bitte erneut versuchen."))) }
    }
    func testLostConsumeResponseIsNeverRetriedAutomatically() async throws {
        let f = try fixture(disconnectOnConsume: true)
        do {
            _ = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: f.snapshot,
                                                    creditID: "credit-1", idempotencyKey: "attempt")
            XCTFail("A lost response must remain unconfirmed")
        } catch { XCTAssertEqual(error.localizedDescription, tr("Einlösung nicht bestätigt. Bitte erneut versuchen.")) }
        XCTAssertEqual(try f.requests().filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }.count, 1)
    }
    func testUnidentifiedLoginAndEmptyIdentifiersNeverStartTheCLI() async throws {
        let f = try fixture()
        var fallback = f.snapshot; fallback.identity = AccountIdentity.fallback(for: f.configuration)
        for (snapshot, credit, key) in [(fallback, "credit-1", "attempt"), (f.snapshot, "", "attempt"), (f.snapshot, "credit-1", "")] {
            do {
                _ = try await CodexResetCredits().redeem(configuration: f.configuration, expectedSnapshot: snapshot, creditID: credit, idempotencyKey: key)
                XCTFail("Invalid redemption must be rejected")
            } catch {}
        }
        XCTAssertTrue(try f.requests().isEmpty)
    }
    func testRegularQuotaReadNeverRedeemsAndUsesTheConfiguredProfile() async throws {
        let f = try fixture()
        let snapshot = try await CodexProvider().read(configuration: f.configuration, includeHistory: false)
        XCTAssertEqual(snapshot.benefitCount, 2)
        XCTAssertEqual(snapshot.identity, f.snapshot.identity)
        XCTAssertFalse(try f.requests().contains { $0["method"] as? String == "account/rateLimitResetCredit/consume" })
    }
}
