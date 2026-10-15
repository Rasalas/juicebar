import XCTest
import Darwin
@testable import JuicebarCore

final class LogDateParserTests: XCTestCase {
    func testMatchesLegacyAcrossDistinctLogTimestamps() {
        let parser = LogDateParser()
        let legacy = legacyParser()
        for index in 0..<1_000 {
            let timestamp = String(format: "2026-10-%02dT%02d:%02d:%02d.%03dZ", 1 + index % 31, index % 24, index % 60, index / 60, index)
            XCTAssertEqual(parser.parse(timestamp), legacy(timestamp), timestamp)
            let whole = String(timestamp.prefix(19)) + "Z"
            XCTAssertEqual(parser.parse(whole), legacy(whole), whole)
        }
    }

    func testPreservesLegacyPrecisionOffsetsAndPermissiveInputs() {
        let parser = LogDateParser()
        let legacy = legacyParser()
        let timestamps = [
            "1969-12-31T23:59:59.999Z", "1970-01-01T00:00:00.001Z",
            "2000-02-29T23:59:59.999Z", "1900-02-29T00:00:00.000Z",
            "2026-12-31T23:59:59.999Z", "2027-01-01T00:00:00Z",
            "2026-10-15T12:34:56.1Z", "2026-10-15T12:34:56.123456789Z",
            "2026-10-15T12:34:56+02:00", "2026-10-15T12:34:56.123-05:30",
            "2026-10-15T12:34:56.123+0000", "2026-10-15T12:34:56.123Ztrailing",
            "2026-02-30T12:34:56.123Z", "2026-13-01T00:00:00.000Z",
            "2026-00-01T00:00:00Z", "2026-01-00T00:00:00Z",
            "2026-10-15T24:00:00.000Z", "2026-10-15T12:60:00.000Z",
            "2016-12-31T23:59:60.000Z", "0000-01-01T00:00:00.000Z",
            "9999-12-31T23:59:59.999Z", "２０２６-10-15T12:34:56Z",
            "2026-10-15T12:34:56.é12Z", "", "invalid", "2026-10-15", "2026-10-15T12:34:56Z💥"
        ]
        for timestamp in timestamps {
            XCTAssertEqual(parser.parse(timestamp), legacy(timestamp), timestamp)
        }
    }

    func testPreservesNumericAndMissingValues() {
        let parser = LogDateParser()
        XCTAssertEqual(parser.parse(1_800_000_000.125), Date(timeIntervalSince1970: 1_800_000_000.125))
        XCTAssertNil(parser.parse(0))
        XCTAssertNil(parser.parse(-1))
        XCTAssertNil(parser.parse(nil))
        XCTAssertNil(parser.parse(["timestamp": 1]))
    }

    // Run with JUICEBAR_BENCHMARK=1 swift test -c release --filter LogDateParserTests/testDateParsingBenchmark.
    func testDateParsingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["JUICEBAR_BENCHMARK"] == "1" else {
            throw XCTSkip("Set JUICEBAR_BENCHMARK=1 to measure date parsing")
        }
        let timestamps = (0..<100_000).map { index in
            String(format: "2026-10-%02dT%02d:%02d:%02d.%03dZ", 1 + index / 86_400,
                   index / 3_600 % 24, index / 60 % 60, index % 60, index % 1_000)
        }
        func resources() -> (cpu: Double, rss: Int) {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
                    Int(usage.ru_maxrss))
        }
        func measure(_ parse: (String) -> Date?) -> (dates: [Date?], checksum: Double, cpu: Double, wall: Double) {
            let before = resources().cpu
            let start = ProcessInfo.processInfo.systemUptime
            let dates = timestamps.map(parse)
            let checksum = dates.reduce(0) { $0 + ($1?.timeIntervalSince1970 ?? 0) }
            return (dates, checksum, resources().cpu - before, ProcessInfo.processInfo.systemUptime - start)
        }
        let baseline = measure(legacyParser())
        let parser = LogDateParser()
        let optimized = measure { parser.parse($0) }
        XCTAssertTrue(baseline.dates.allSatisfy { $0 != nil })
        XCTAssertEqual(optimized.dates, baseline.dates)
        XCTAssertEqual(optimized.checksum, baseline.checksum)
        print("BENCHMARK date parsing 100000 distinct: legacyCPU=\(baseline.cpu)s legacyWall=\(baseline.wall)s optimizedCPU=\(optimized.cpu)s optimizedWall=\(optimized.wall)s checksum=\(optimized.checksum) processPeakRSS=\(resources().rss) bytes")
    }

    private func legacyParser() -> (String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let whole = ISO8601DateFormatter()
        return { fractional.date(from: $0) ?? whole.date(from: $0) }
    }
}
