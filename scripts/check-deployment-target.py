#!/usr/bin/env python3
"""Check declared and linked minimum OS versions. This is NOT a macOS 14 runtime test."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


def require_macos14(value):
    if not re.fullmatch(r"14\.0(?:\.0)?", str(value)):
        raise ValueError(f"Expected macOS 14.0 deployment target, got {value!r}")


def check_build_versions(output):
    # vtool prints a file header for thin binaries and a header per universal slice,
    # even when a slice contains no build-version command. Check those empty slices too.
    slices = re.split(r"^[^\s][^\n]*:[ \t]*\n", output, flags=re.MULTILINE)
    if len(slices) < 2 or slices[0].strip():
        raise ValueError("Expected a vtool header for every executable architecture")
    for block in slices[1:]:
        commands = re.findall(r"^\s*cmd\s+(\S+)", block, re.MULTILINE)
        if commands != ["LC_BUILD_VERSION"]:
            raise ValueError("Expected one LC_BUILD_VERSION in every executable architecture")
        platform = re.search(r"^\s*platform\s+(\S+)", block, re.MULTILINE)
        minimum = re.search(r"^\s*minos\s+(\S+)", block, re.MULTILINE)
        if not platform or platform[1] != "MACOS" or not minimum:
            raise ValueError("Expected a macOS build-version record in every architecture")
        require_macos14(minimum[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--info-plist", type=Path, default=Path("assets/Info.plist"))
    args = parser.parse_args()
    package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
    platforms = [p["version"] for p in package["platforms"] if p["platformName"] == "macos"]
    if len(platforms) != 1:
        raise ValueError("Package must declare one macOS minimum")
    require_macos14(platforms[0])
    with args.info_plist.open("rb") as stream:
        require_macos14(plistlib.load(stream).get("LSMinimumSystemVersion"))
    check_build_versions(subprocess.check_output(["xcrun", "vtool", "-show-build", str(args.binary)], text=True))
    print("PASS: Package, Info.plist and executable target macOS 14.0. macOS 14 runtime remains unverified.")


if __name__ == "__main__":
    main()
