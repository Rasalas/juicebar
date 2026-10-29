"""Synthetic validation of the deployment gate and AX status adapter; no app launch."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deployment", ROOT / "scripts/check-deployment-target.py")
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)
performance_spec = importlib.util.spec_from_file_location("performance", ROOT / "scripts/check-performance-results.py")
performance = importlib.util.module_from_spec(performance_spec)
performance_spec.loader.exec_module(performance)


class PerformanceResultsTests(unittest.TestCase):
    def report(self, names=None, outcome="passed", objective_c=False):
        names = performance.EXPECTED if names is None else names
        return "\n".join(
            f"Test Case '-[Module.Class {name}]' {outcome} (0.1 seconds)." if objective_c
            else f"Test Case 'Module.Class.{name}' {outcome} (0.1 seconds)." for name in names
        )

    def test_requires_exactly_the_three_passing_cases(self):
        performance.check_results(self.report())
        performance.check_results(self.report(objective_c=True))
        for output in [self.report([]), self.report(["testUnchangedImport"]),
                       self.report(outcome="skipped"), self.report(outcome="failed"),
                       self.report(list(performance.EXPECTED) * 2), "Build complete!\nExecuted 0 tests"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                performance.check_results(output)


class DeploymentTargetTests(unittest.TestCase):
    def record(self, version="14.0", platform="MACOS", architecture=None):
        header = "fixture (architecture " + architecture + ")" if architecture else "fixture"
        return f"{header}:\nLoad command 1\n      cmd LC_BUILD_VERSION\n platform {platform}\n minos {version}\n sdk 27.0\n"

    def test_accepts_macos14_in_every_architecture(self):
        deployment.check_build_versions(self.record())
        deployment.check_build_versions(self.record(architecture="arm64") + self.record("14.0.0", architecture="x86_64"))

    def test_rejects_universal_slice_without_build_version(self):
        valid = self.record(architecture="arm64")
        missing = "fixture (architecture x86_64):\n"
        for output in [valid + missing, missing + valid, missing, "fixture:\n"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                deployment.check_build_versions(output)

    def test_rejects_duplicate_commands_and_unframed_output(self):
        command = self.record().split("fixture:\n")[1]
        for output in [command, "fixture:\n" + command + command]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                deployment.check_build_versions(output)

    def test_rejects_missing_wrong_platform_and_raised_minimum(self):
        for output in ["", self.record(platform="IOS"), self.record("15.0"),
                       self.record() + self.record("15.0"), "cmd LC_BUILD_VERSION\n platform MACOS",
                       self.record() + "cmd LC_VERSION_MIN_MACOSX\n version 15.0"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                deployment.check_build_versions(output)

    def test_declared_minimum_cannot_silently_change(self):
        for value in [None, "13.0", "14.1", "15.0", "14.0junk"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                deployment.require_macos14(value)


class AccessibilityScriptTests(unittest.TestCase):
    def run_probe(self, status):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = directory / "probe"
            fixture.write_text(f'#!/bin/bash\n[[ "$1" == --verify-quota-accessibility ]] || exit 99\nexit {status}\n')
            fixture.chmod(0o700)
            summary = directory / "summary"
            result = subprocess.run(["bash", str(ROOT / "scripts/check-accessibility.sh"), str(fixture)],
                                    env={**os.environ, "GITHUB_ACTIONS": "true", "GITHUB_STEP_SUMMARY": str(summary)},
                                    text=True, capture_output=True)
            return result, summary.read_text() if summary.exists() else ""

    def test_unavailable_tree_is_an_explicit_warning_and_summary(self):
        result, summary = self.run_probe(2)
        self.assertEqual(result.returncode, 0)
        self.assertIn("::warning::", result.stdout)
        self.assertIn("NOT performed", summary)
        self.assertNotIn("passed", summary)

    def test_semantic_failure_is_not_swallowed(self):
        for status in [1, 9]:
            result, summary = self.run_probe(status)
            self.assertEqual(result.returncode, status)
            self.assertNotIn("passed", summary)

    def test_success_still_does_not_claim_voiceover(self):
        result, summary = self.run_probe(0)
        self.assertEqual(result.returncode, 0)
        self.assertIn("VoiceOver interaction remains unverified", summary)


if __name__ == "__main__":
    unittest.main()
