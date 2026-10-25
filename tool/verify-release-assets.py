#!/usr/bin/env python3
"""Fail a draft release unless all three native packages and source are present."""
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
files = {p.name: p for p in root.iterdir() if p.is_file() and p.name != 'SHA256SUMS'}
source = [name for name in files if re.fullmatch(r'Portly-\d+\.\d+\.\d+-source.zip', name)]
if len(source) != 1:
    raise SystemExit('Exactly one corresponding source archive is required')
version = source[0][len('Portly-'):-len('-source.zip')]
expected = {source[0], f'Portly-{version}-macOS-arm64.dmg', f'Portly-{version}-macOS-arm64.zip'}
for arch in ['x64', 'arm64']:
    base = f'Portly-{version}-windows-{arch}'
    expected.update({base + '-portable.zip', base + '-setup.exe', base + '-manifest.json', base + '-smoke.json'})
    report = files.get(base + '-smoke.json')
    if report is None:
        raise SystemExit(f'Missing native installation report: {arch}')
    smoke = json.loads(report.read_text(encoding='utf-8-sig'))
    if smoke.get('passed') is not True or smoke.get('forcedCleanup') is not False:
        raise SystemExit(f'Native installation did not pass: {arch}')
if expected - files.keys():
    raise SystemExit(f'Missing release files: {expected - files.keys()}')
checked = set()
for name, path in files.items():
    if not (name.endswith('.sha256') or name.endswith('-SHA256SUMS.txt')):
        continue
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?(.+)', line)
        if not match or Path(match[2]).name != match[2] or match[2] not in files:
            raise SystemExit(f'Invalid checksum member in {name}')
        member = files[match[2]]
        if hashlib.sha256(member.read_bytes()).hexdigest() != match[1].lower():
            raise SystemExit(f'Checksum mismatch: {member.name}')
        checked.add(member.name)
if {name for name in expected if name.endswith(('.exe', '.zip', '.dmg', '-manifest.json'))} - checked:
    raise SystemExit('Some binary/source artifacts have no verified checksum')
lines = [f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {name}' for name, path in sorted(files.items())]
(root / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
print(f'All {len(expected)} required assets and native installation reports verified for {version}')
