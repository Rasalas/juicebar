#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Fixed, bounded synthetic profile. Keep large archive/peak-memory stress tests opt-in.
export JUICEBAR_BENCHMARK=1
export JUICEBAR_BENCHMARK_PROFILE=ci
mkdir -p .artifacts/validation
results=.artifacts/validation/performance.log
rm -f "$results"
swift test -c release --filter 'ActivityPerformanceTests/(testUnchangedImport|testAppendToLargeLog|testColdRemoteSnapshotsAreReused)$|LogDateParserTests/testDateParsingBenchmark$' 2>&1 | tee "$results"
python3 scripts/check-performance-results.py "$results"
