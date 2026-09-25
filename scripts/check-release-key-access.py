#!/usr/bin/env python3
"""Sign one existing archive twice. A waiting Keychain dialog fails this unattended check."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
    raise SystemExit('Usage: python3 scripts/check-release-key-access.py release.zip')
root = Path(os.environ.get('JUICEBAR_RELEASE_TOOLS', Path.home() / 'Library/Application Support/Juicebar Release Tools'))
with tempfile.TemporaryDirectory(prefix='juicebar-key-check-') as directory:
    shutil.copyfile(sys.argv[1], Path(directory) / Path(sys.argv[1]).name)
    for number in range(1, 3):
        start = time.monotonic()
        try:
            result = subprocess.run([str(root / 'generate_appcast'), '--account', 'juicebar', directory],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except subprocess.TimeoutExpired:
            raise SystemExit('FAIL: signing waited more than 15 seconds; check Keychain authorization.')
        feed = Path(directory) / 'appcast.xml'
        enclosure = ET.parse(feed).find('.//enclosure') if feed.exists() else None
        if result.returncode or enclosure is None or not enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'):
            raise SystemExit('FAIL: no signed feed produced.')
        print(f'PASS: signing {number}/2 completed unattended in {time.monotonic() - start:.2f}s')
