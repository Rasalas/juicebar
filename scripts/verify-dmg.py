#!/usr/bin/env python3
"""Verify the signed app before and after a normal copy out of its DMG."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path)
args = parser.parse_args()
attached = plistlib.loads(subprocess.check_output([
    'hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(args.image.resolve())
]))
mounts = [Path(entry['mount-point']) for entry in attached['system-entities'] if 'mount-point' in entry]
try:
    if len(mounts) != 1:
        raise SystemExit('Expected exactly one mounted installer volume')
    volume = mounts[0]
    if os.readlink(volume / 'Applications') != '/Applications':
        raise SystemExit('Installer Applications shortcut is invalid')
    app = volume / 'Juicebar.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix='juicebar-install-check-') as directory:
        copied = Path(directory) / 'Juicebar.app'
        subprocess.run(['ditto', str(app), str(copied)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copied)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(copied)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose', str(copied)], check=True)
        with (copied / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        print(f"Installer copy verified: {info['CFBundleShortVersionString']} build {info['CFBundleVersion']}")
finally:
    for volume in mounts:
        subprocess.run(['hdiutil', 'detach', str(volume)], check=True)
