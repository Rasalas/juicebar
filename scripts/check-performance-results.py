#!/usr/bin/env python3
"""Fail if a renamed filter, skip or missing profile silently drops CI benchmarks."""
from collections import Counter
from pathlib import Path
import re
import sys

EXPECTED = Counter({
    "testUnchangedImport": 1,
    "testAppendToLargeLog": 1,
    "testDateParsingBenchmark": 1,
})


def check_results(output):
    # XCTest prints either Module.Class.testMethod or -[Module.Class testMethod].
    # SwiftPM's --xunit-output does not emit a report with every macOS toolchain.
    cases = re.findall(r"Test Case '([^']+)' (passed|skipped|failed)", output)
    names = [re.search(r"(test\w+)(?:\(\))?\]?$", name) for name, _ in cases]
    if any(name is None for name in names) or Counter(name[1] for name in names) != EXPECTED:
        raise ValueError("Expected exactly the three bounded performance cases")
    if any(status != "passed" for _, status in cases):
        raise ValueError("All three performance cases must pass without skips")


if __name__ == "__main__":
    check_results(Path(sys.argv[1]).read_text())
    print("PASS: all three bounded release benchmarks executed without skips.")
