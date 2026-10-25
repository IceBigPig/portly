#!/usr/bin/env python3
"""Create the complete, rebuildable source ZIP without local build/user data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOP_FILES = {
    '.gitattributes', '.gitignore', '.metadata', 'README.md', 'LICENSE', 'NOTICE',
    'THIRD_PARTY_NOTICES.md', 'analysis_options.yaml', 'pubspec.yaml', 'pubspec.lock',
}
TREES = {'.github', 'lib', 'assets', 'test', 'tool', 'packaging', 'macos', 'windows',
         'linux', 'web', 'docs', 'third_party_licenses'}
BLOCKED = {'.git', '.dart_tool', 'build', 'Pods', 'ephemeral', '__pycache__',
           'xcuserdata', '.symlinks', 'releases', 'dist'}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', default='releases')
    parser.add_argument('--overwrite', action='store_true')
    args = parser.parse_args()
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$',
                        (ROOT / 'pubspec.yaml').read_text(), re.M)[1]
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    target = output / f'Portly-{version}-source.zip'
    if target.exists() and not args.overwrite:
        raise SystemExit(f'Already exists: {target}')
    raw = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    paths = []
    for name in sorted(set(raw.decode().split('\0')) - {''}):
        p = Path(name)
        if p.parts[0] not in TREES and name not in TOP_FILES:
            continue
        if any(part in BLOCKED for part in p.parts) or p.name == '.DS_Store' or p.suffix in {'.pyc', '.log'}:
            continue
        actual = ROOT / p
        if actual.is_symlink() or not actual.is_file():
            raise SystemExit(f'Unexpected source member: {name}')
        paths.append(p)
    required = ['LICENSE', 'NOTICE', 'pubspec.lock', 'lib/main.dart',
                'tool/package-macos.sh', 'tool/package-windows.ps1',
                'third_party_licenses/REBUILDING-LGPL.md']
    names = {p.as_posix() for p in paths}
    if not set(required) <= names:
        raise SystemExit(f'Missing rebuild inputs: {set(required) - names}')
    sources = [p for p in paths if p.as_posix().startswith('third_party_licenses/sources/') and p.name.endswith('.tar.gz')]
    if len(sources) < 3:
        raise SystemExit('LGPL corresponding source archives are missing')
    manifest = {'version': version, 'files': []}
    prefix = f'Portly-{version}-source/'
    temporary = target.with_suffix('.zip.partial')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for p in paths:
                data = (ROOT / p).read_bytes()
                digest = hashlib.sha256(data).hexdigest()
                manifest['files'].append({'path': p.as_posix(), 'bytes': len(data), 'sha256': digest})
                info = zipfile.ZipInfo(prefix + p.as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = ((0o100755 if (ROOT / p).stat().st_mode & 0o111 else 0o100644) << 16)
                archive.writestr(info, data)
            info = zipfile.ZipInfo(prefix + 'SOURCE-MANIFEST.json', date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise SystemExit('ZIP CRC verification failed')
            for entry in manifest['files']:
                if hashlib.sha256(archive.read(prefix + entry['path'])).hexdigest() != entry['sha256']:
                    raise SystemExit('Source ZIP hash mismatch')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_suffix('.zip.sha256').write_text(f'{digest}  {target.name}\n')
    print(json.dumps({'archive': target.name, 'sha256': digest, 'files': len(paths), 'bytes': target.stat().st_size}))


if __name__ == '__main__':
    main()
