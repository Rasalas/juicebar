import XCTest
import Darwin
@testable import JuicebarCore

final class ProcessTransportTests: XCTestCase {
    func testBlockedInputHonorsDeadline() throws {
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], timeout: 0.05)
        defer { client.close() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.sendInput(Data(repeating: 65, count: 1_048_576))) {
            XCTAssertEqual($0 as? ProviderFailure, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testBlockedJSONSendHonorsDeadline() throws {
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], timeout: 0.05)
        defer { client.close() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.send(["payload": String(repeating: "a", count: 1_048_576)])) {
            XCTAssertEqual($0 as? ProviderFailure, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testSendDrainsStdoutAndPreservesRepliesAndPartialWrites() throws {
        let script = """
        import sys,json
        print(json.dumps({'early':'x'*200000}),flush=True)
        data=sys.stdin.buffer.read()
        print(json.dumps({'ok':data == bytes(range(256))*4096}),flush=True)
        """
        let client = try python(script, timeout: 5)
        defer { client.close() }
        let data = Data((0..<1_048_576).map { UInt8($0 % 256) })
        try client.sendInput(data, finish: true)
        XCTAssertEqual(try client.receive { $0["early"] != nil }["early"] as? String, String(repeating: "x", count: 200000))
        XCTAssertEqual(try client.receive { $0["ok"] != nil }["ok"] as? Bool, true)
    }

    func testOutputFloodDuringWriteStopsAtCap() throws {
        let client = try python("import sys; sys.stdout.write('x'*1000000); sys.stdout.flush(); sys.stdin.buffer.read()", maximumResponseBytes: 16_384)
        defer { client.close() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.sendInput(Data(repeating: 65, count: 1_048_576))) {
            XCTAssertEqual($0 as? ProviderFailure, .invalidData(tr("Die Anbieterantwort ist zu groß.")))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testReceiveEnforcesCapWithoutNewline() throws {
        let client = try python("import sys,time; sys.stdout.write('x'*1000000); sys.stdout.flush(); time.sleep(30)", maximumResponseBytes: 16_384)
        defer { client.close() }
        XCTAssertThrowsError(try client.receive { _ in true }) {
            XCTAssertEqual($0 as? ProviderFailure, .invalidData(tr("Die Anbieterantwort ist zu groß.")))
        }
    }

    func testReceiveAcceptsExactCapAndDrainsAfterExit() throws {
        let data = "{\"ok\":true}\n"
        let client = try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [data], maximumResponseBytes: data.utf8.count)
        defer { client.close() }
        XCTAssertEqual(try client.receive { _ in true }["ok"] as? Bool, true)
    }

    func testCancellationInterruptsBlockedWriteAndCleansChild() async throws {
        try await assertCancellation(duringWrite: true)
    }

    func testCancellationInterruptsBlockedReadAndCleansChild() async throws {
        try await assertCancellation(duringWrite: false)
    }

    private func assertCancellation(duringWrite: Bool) async throws {
        let ready = expectation(description: "child is ready")
        let task = Task.detached { () throws -> pid_t in
            let client = try self.python("import os,json,time; print(json.dumps({'pid':os.getpid()}),flush=True); time.sleep(30)", timeout: 10)
            defer { client.close() }
            let pid = pid_t(try XCTUnwrap(client.receive { _ in true }["pid"] as? Int))
            ready.fulfill()
            do {
                if duringWrite { try client.sendInput(Data(repeating: 65, count: 1_048_576)) }
                else { _ = try client.receive { _ in true } }
                XCTFail("Cancelled I/O succeeded")
            } catch is CancellationError { }
            return pid
        }
        await fulfillment(of: [ready], timeout: 3)
        // Leave the worker inside its blocked poll before requesting cancellation.
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let pid = try await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCloseCleansHelpersAfterLeaderAlreadyExitedAndLeavesOtherGroupsAlone() throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let script = """
        import os,signal,json,time
        leader=os.getpid()
        if os.fork() == 0:
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            print(json.dumps({'pid':os.getpid(),'leader':leader}),flush=True)
            time.sleep(30)
        else:
            os._exit(0)
        """
        let client = try python(script)
        defer { client.close() }
        let row = try client.receive { _ in true }
        let helper = pid_t(try XCTUnwrap(row["pid"] as? Int))
        let leader = pid_t(try XCTUnwrap(row["leader"] as? Int))
        // Observe the exit without releasing the pid reserved by ProcessClient.
        var info = siginfo_t()
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < end {
            if waitid(P_PID, id_t(leader), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == leader { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(info.si_pid, leader)
        client.close()
        client.close() // Cleanup is idempotent, including after the leader has been reaped.
        let gone = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(helper, 0) == 0 && ContinuousClock.now < gone { Thread.sleep(forTimeInterval: 0.01) }
        let survived = kill(helper, 0) == 0
        if survived { kill(helper, SIGKILL) }
        XCTAssertFalse(survived)
        XCTAssertTrue(unrelated.isRunning)
    }

    func testCloseKillsOwnedLeaderAfterItChangesGroups() throws {
        let script = """
        import os,signal,json
        os.setpgid(0,os.getpgid(os.getppid()))
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        signal.alarm(3)
        print(json.dumps({'pid':os.getpid(),'group':os.getpgrp()}),flush=True)
        while True: signal.pause()
        """
        let client = try python(script, timeout: 5)
        defer { client.close() }
        let row = try client.receive { _ in true }
        let pid = pid_t(try XCTUnwrap(row["pid"] as? Int))
        XCTAssertNotEqual(row["group"] as? Int, Int(pid))
        let start = ContinuousClock.now
        client.close()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1.2), "Cleanup must kill the owned PID rather than wait for its alarm")
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func python(_ script: String, timeout: TimeInterval = 3, maximumResponseBytes: Int = 2_000_000) throws -> ProcessClient {
        try ProcessClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], timeout: timeout, maximumResponseBytes: maximumResponseBytes)
    }
}

final class HTTPTransportTests: XCTestCase {
    func testStreamsValidJSONAtExactLimit() async throws {
        let prefix = Data("{\"pad\":\"".utf8), suffix = Data("\"}".utf8)
        let data = prefix + Data(repeating: 65, count: HTTPTransport.maximumBytes - prefix.count - suffix.count) + suffix
        let fixture = HTTPFixture(body: data)
        let result = try await get(fixture)
        XCTAssertEqual((result["pad"] as? String)?.utf8.count, HTTPTransport.maximumBytes - prefix.count - suffix.count)
    }

    func testRejectsOversizedContentLengthWithoutWaitingForBody() async throws {
        // URL loading may defer header delivery until the first body byte. Stop the fixture
        // there so rejection cannot depend on producer speed or on receiving the rest.
        let fixture = HTTPFixture(headers: ["Content-Type": "application/json", "Content-Length": "\(HTTPTransport.maximumBytes + 1)"], body: Data([65]), stall: true)
        await assertFailure(fixture, .invalidData(tr("Die Anbieterantwort ist zu groß.")))
        XCTAssertLessThanOrEqual(fixture.bytesSent, 1)
        await fulfillment(of: [fixture.stopped], timeout: 2)
    }

    func testUnknownLengthStopsReceptionAtLimit() async throws {
        // No end-of-body callback: the byte cap itself must finish the request.
        let fixture = HTTPFixture(body: Data(repeating: 65, count: HTTPTransport.maximumBytes + 1), stall: true)
        await assertFailure(fixture, .invalidData(tr("Die Anbieterantwort ist zu groß.")))
        XCTAssertEqual(fixture.bytesSent, HTTPTransport.maximumBytes + 1)
        await fulfillment(of: [fixture.stopped], timeout: 2)
    }

    func testRejectsHugeErrorBodiesAtHeadersAndPreservesSafeErrors() async throws {
        let failures: [(Int, ProviderFailure)] = [
            (401, .authentication),
            (403, .unsupported(tr("Der Anbieter verweigert den Zugriff. Berechtigungen und aktives Abonnement prüfen."))),
            (404, .unsupported(tr("Diese Datenquelle ist für das Konto nicht verfügbar."))),
            (429, .rateLimited(120)), (500, .network)
        ]
        for (status, failure) in failures {
            let fixture = HTTPFixture(status: status, headers: ["Content-Type": "application/json", "Retry-After": "120", "Content-Length": "8000000"],
                                      body: Data([65]), stall: true)
            await assertFailure(fixture, failure)
            XCTAssertLessThanOrEqual(fixture.bytesSent, 1)
            await fulfillment(of: [fixture.stopped], timeout: 2)
        }
    }

    func testUnderstatedContentLengthStillStopsAtLimit() async throws {
        let fixture = HTTPFixture(headers: ["Content-Length": "1"], body: Data(repeating: 65, count: HTTPTransport.maximumBytes + 1), stall: true)
        await assertFailure(fixture, .invalidData(tr("Die Anbieterantwort ist zu groß.")))
        XCTAssertEqual(fixture.bytesSent, HTTPTransport.maximumBytes + 1)
        await fulfillment(of: [fixture.stopped], timeout: 2)
    }

    func testCancellingOneRequestLeavesSharedSessionUsable() async throws {
        let stalled = HTTPFixture(stall: true, beforeHeaders: true), success = HTTPFixture()
        let stalledURL = URL(string: "https://transport.invalid/\(UUID())")!, successURL = URL(string: "https://transport.invalid/\(UUID())")!
        HTTPFixtureProtocol.register(stalled, url: stalledURL)
        HTTPFixtureProtocol.register(success, url: successURL)
        defer { HTTPFixtureProtocol.remove(url: stalledURL); HTTPFixtureProtocol.remove(url: successURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = Task { try await HTTPTransport.get(stalledURL, headers: [:], session: session) }
        await fulfillment(of: [stalled.started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let result = try await HTTPTransport.get(successURL, headers: [:], session: session)
        XCTAssertTrue(result.isEmpty)
        await fulfillment(of: [stalled.stopped], timeout: 2)
    }

    func testRetryAfterFallbackAndBounds() async throws {
        for (raw, expected) in [("invalid", 300.0), ("1", 60.0), ("999999", 86400.0)] {
            await assertFailure(HTTPFixture(status: 429, headers: ["Retry-After": raw]), .rateLimited(expected))
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let raw = formatter.string(from: Date().addingTimeInterval(180))
        do {
            _ = try await get(HTTPFixture(status: 429, headers: ["Retry-After": raw]))
            XCTFail("Expected rate limit")
        } catch ProviderFailure.rateLimited(let delay) { XCTAssertEqual(delay, 180, accuracy: 3) }
    }

    func testCancellationStopsReceptionBeforeHeaders() async throws {
        try await assertCancellation(beforeHeaders: true)
    }

    func testCancellationStopsReceptionDuringBody() async throws {
        try await assertCancellation(beforeHeaders: false)
    }

    func testCancelledTaskDoesNotStartRequest() async throws {
        let fixture = HTTPFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.get(fixture)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.bytesSent, 0)
    }

    func testNetworkAndMalformedJSONErrorsStaySafe() async throws {
        await assertFailure(HTTPFixture(error: URLError(.timedOut)), .network)
        await assertFailure(HTTPFixture(body: Data("private invalid provider response".utf8)), .network)
        await assertFailure(HTTPFixture(body: Data("[]".utf8)), .invalidData(tr("Unbekanntes Antwortformat. Adapter aktualisieren.")))
    }

    private func assertCancellation(beforeHeaders: Bool) async throws {
        let fixture = HTTPFixture(body: Data("{".utf8), stall: true, beforeHeaders: beforeHeaders)
        let task = Task { try await self.get(fixture) }
        await fulfillment(of: [fixture.started], timeout: 2)
        if !beforeHeaders { await fulfillment(of: [fixture.firstChunk], timeout: 2) }
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        await fulfillment(of: [fixture.stopped], timeout: 2)
    }

    private func assertFailure(_ fixture: HTTPFixture, _ expected: ProviderFailure) async {
        do { _ = try await get(fixture); XCTFail("Expected transport failure") }
        catch { XCTAssertEqual(error as? ProviderFailure, expected) }
    }

    private func get(_ fixture: HTTPFixture) async throws -> [String: Any] {
        let url = URL(string: "https://transport.invalid/\(UUID())")!
        HTTPFixtureProtocol.register(fixture, url: url)
        defer { HTTPFixtureProtocol.remove(url: url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPFixtureProtocol.self]
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await HTTPTransport.get(url, headers: ["X-Fixture": "synthetic"], session: session)
    }
}

/// In-memory URL loading only. Every request has its own fixture and cannot reach a provider.
private final class HTTPFixture {
    let status: Int, headers: [String: String], body: Data, error: Error?, stall: Bool, beforeHeaders: Bool
    let started = XCTestExpectation(description: "request started")
    let stopped = XCTestExpectation(description: "request stopped")
    let firstChunk = XCTestExpectation(description: "body started")
    private let lock = NSLock()
    private var sent = 0
    var bytesSent: Int { lock.withLock { sent } }
    func record(_ count: Int) { lock.withLock { sent += count } }
    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data("{}".utf8), error: Error? = nil, stall: Bool = false, beforeHeaders: Bool = false) {
        self.status = status; self.headers = headers; self.body = body; self.error = error
        self.stall = stall; self.beforeHeaders = beforeHeaders
    }
}

private final class HTTPFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [URL: HTTPFixture] = [:]
    static func register(_ fixture: HTTPFixture, url: URL) { lock.withLock { fixtures[url] = fixture } }
    static func remove(url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let queue = DispatchQueue(label: "juicebar.transport-fixture")
    private var fixture: HTTPFixture?
    private var offset = 0
    private var stopped = false
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixtures[request.url!]! }
        queue.async {
            self.fixture = fixture
            fixture.started.fulfill()
            guard !fixture.beforeHeaders else { return }
            if let error = fixture.error { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { self.pump() }
        }
    }
    private func pump() {
        guard !stopped, let fixture else { return }
        if offset == fixture.body.count {
            if !fixture.stall { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        let count = min(16_384, fixture.body.count - offset)
        let chunk = fixture.body.subdata(in: offset..<(offset + count))
        fixture.record(count)
        client?.urlProtocol(self, didLoad: chunk)
        if offset == 0 { fixture.firstChunk.fulfill() }
        offset += count
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { self.pump() }
    }
    override func stopLoading() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.fixture?.stopped.fulfill()
        }
    }
}
