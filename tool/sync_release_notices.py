#!/usr/bin/env python3
"""Bind a staging license copy to the actual Release NOTICES.Z, without pub/Flutter.

Only FLUTTER-NOTICES.txt, its manifest field, and SHA256SUMS may change.
The committed license baseline is deliberately never modified by this helper.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[1]
MUTABLE = {'FLUTTER-NOTICES.txt', 'dependency-manifest.json', 'SHA256SUMS'}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def local_file(uri: str) -> Path:
    parsed = urlparse(uri)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise RuntimeError('Expected a local file URI in package_config.json')
    return Path(url2pathname(parsed.path)).resolve()


def checked_path(directory: Path, relative: str) -> Path:
    if '\\' in relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise RuntimeError(f'Unsafe license material path: {relative}')
    path = directory / relative
    if not path.resolve().is_relative_to(directory) or not path.is_file() or path.is_symlink():
        raise RuntimeError(f'Missing or unsafe license material: {relative}')
    return path


def verify_materials(directory: Path) -> tuple[dict[str, str], list[str], dict]:
    lines = (directory / 'SHA256SUMS').read_text(encoding='utf-8').splitlines()
    hashes: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match or match[2] in hashes or match[2] == 'SHA256SUMS':
            raise RuntimeError('Invalid or duplicate SHA256SUMS entry')
        expected, relative = match.groups()
        if sha256(checked_path(directory, relative).read_bytes()) != expected:
            raise RuntimeError(f'License checksum mismatch: {relative}')
        hashes[relative] = expected
    actual = {path.relative_to(directory).as_posix() for path in directory.rglob('*')
              if path.is_file() and path.relative_to(directory).as_posix() != 'SHA256SUMS'}
    if actual != set(hashes):
        raise RuntimeError('License checksum inventory is incomplete or has missing files')
    manifest = json.loads(checked_path(directory, 'dependency-manifest.json').read_text(encoding='utf-8'))
    if manifest.get('flutter_notices_sha256') != hashes.get('FLUTTER-NOTICES.txt'):
        raise RuntimeError('Baseline Flutter notices hash differs from its dependency manifest')
    sources = manifest.get('corresponding_sources', [])
    if len(sources) < 3:
        raise RuntimeError('Corresponding LGPL source archives are missing')
    for source in sources:
        file = source['file']
        if file not in hashes or hashes[file] != source.get('sha256'):
            raise RuntimeError(f'Corresponding source archive differs from its manifest: {file}')
    return hashes, lines, manifest


def verify_resolved_build(project: Path, manifest: dict) -> dict:
    lock = project / 'pubspec.lock'
    lock_hash = sha256(lock.read_bytes())
    if lock_hash != manifest.get('pubspec_lock_sha256'):
        raise RuntimeError('Resolved pubspec.lock differs from the collected license baseline; recollect licenses')
    locked: dict[str, dict] = {}
    current = None
    for line in lock.read_text(encoding='utf-8').splitlines():
        package = re.fullmatch(r'  ([A-Za-z0-9_]+):', line)
        if package:
            current = locked.setdefault(package[1], {})
        elif current is not None:
            value = re.fullmatch(r'    (version|source): (.+)', line)
            if value:
                current[value[1]] = value[2].strip('"\'')
            archive = re.fullmatch(r'      sha256: (.+)', line)
            if archive:
                current['pub_archive_sha256'] = archive[1].strip('"\'')
    package_config = project / '.dart_tool/package_config.json'
    config = json.loads(package_config.read_text(encoding='utf-8'))
    expected = {package['name']: package for package in manifest['packages']}
    if len(expected) != len(manifest['packages']) or set(locked) != set(expected):
        raise RuntimeError('Dependency package inventory differs from pubspec.lock')
    resolved = {package['name']: package for package in config['packages'] if package['name'] != 'portly'}
    if set(resolved) != set(expected):
        raise RuntimeError('Resolved package_config inventory differs from the collected licenses')
    if config.get('flutterVersion') != manifest.get('flutter_version') or config.get('generatorVersion') != manifest.get('dart_version'):
        raise RuntimeError('Resolved Flutter/Dart version differs from the collected license baseline')
    sdk = local_file(config['flutterRoot'])
    sdk_info = json.loads((sdk / 'bin/cache/flutter.version.json').read_text(encoding='utf-8'))
    sdk_flutter = sdk_info.get('flutterVersion', sdk_info.get('frameworkVersion'))
    sdk_dart = re.match(r'^([0-9]+\.[0-9]+\.[0-9]+(?:-[^\s]+)?)', sdk_info.get('dartSdkVersion', ''))
    if sdk_flutter != manifest['flutter_version'] or not sdk_dart or sdk_dart[1] != manifest['dart_version']:
        raise RuntimeError('Actual Flutter SDK version differs from the collected license baseline')
    for name, package in expected.items():
        for field in ('version', 'source', 'pub_archive_sha256'):
            if locked[name].get(field) != package.get(field):
                raise RuntimeError(f'Locked dependency identity differs from license baseline: {name}')
        root = local_file(urljoin(package_config.as_uri(), resolved[name]['rootUri']))
        if package['source'] == 'sdk':
            if not root.is_relative_to(sdk):
                raise RuntimeError(f'Resolved SDK package comes from a different SDK: {name}')
        else:
            content = (root / 'pubspec.yaml').read_text(encoding='utf-8')
            version = re.search(r'^version:\s*[\'"]?([^\s\'"]+)', content, re.MULTILINE)
            if not version or version[1] != package['version']:
                raise RuntimeError(f'Actual resolved dependency version differs: {name}')
    return {'pubspecLockSha256': lock_hash, 'resolvedPackagesVerified': len(expected),
            'flutterVersion': sdk_flutter, 'dartVersion': sdk_dart[1],
            'flutterRevision': sdk_info.get('frameworkRevision'),
            'engineRevision': sdk_info.get('engineRevision')}


def atomic_write(path: Path, content: bytes) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as file:
            file.write(content)
        Path(temporary).chmod(0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def synchronize_notices(app_notices: Path, staged_licenses: Path, project_root: Path = ROOT,
                        *, verify_only: bool = False) -> dict:
    directory, project = staged_licenses.resolve(), project_root.resolve()
    baseline = project / 'third_party_licenses'
    if directory == baseline or directory.is_relative_to(baseline):
        raise RuntimeError('Only a packaging staging copy may be synchronized; committed licenses are read-only')
    if not directory.is_dir() or staged_licenses.is_symlink():
        raise RuntimeError('Staged license directory is missing or unsafe')
    before, lines, manifest = verify_materials(directory)
    identity = verify_resolved_build(project, manifest)
    compressed = app_notices.read_bytes()
    if not compressed.startswith(b'\x1f\x8b'):
        raise RuntimeError('Expected an actual gzip-compressed Release NOTICES.Z')
    decoded = gzip.decompress(compressed)
    if not decoded.strip():
        raise RuntimeError('Release NOTICES.Z has no license text')
    decoded.decode('utf-8')  # Reject unexpected/corrupt text before changing staging.
    actual_hash = sha256(decoded)
    changed = actual_hash != before['FLUTTER-NOTICES.txt']
    if verify_only and changed:
        raise RuntimeError('Packaged Flutter license text does not match the actual NOTICES.Z')
    if changed:
        manifest['flutter_notices_sha256'] = actual_hash
        manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        replacements = {'FLUTTER-NOTICES.txt': decoded, 'dependency-manifest.json': manifest_bytes}
        replacement_hashes = {name: sha256(content) for name, content in replacements.items()}
        checksum_lines = []
        for line in lines:
            _, relative = line.split('  ', 1)
            checksum_lines.append(f'{replacement_hashes[relative]}  {relative}' if relative in replacement_hashes else line)
        replacements['SHA256SUMS'] = ('\n'.join(checksum_lines) + '\n').encode('utf-8')
        originals = {name: (directory / name).read_bytes() for name in replacements}
        try:
            for name, content in replacements.items():
                atomic_write(directory / name, content)
        except BaseException:
            for name, content in originals.items():
                atomic_write(directory / name, content)
            raise
    after, _, current = verify_materials(directory)
    if {name: value for name, value in before.items() if name not in MUTABLE} != {
            name: value for name, value in after.items() if name not in MUTABLE}:
        raise RuntimeError('Non-notice license material changed during synchronization')
    if after['FLUTTER-NOTICES.txt'] != actual_hash or current['flutter_notices_sha256'] != actual_hash:
        raise RuntimeError('As-built notice synchronization verification failed')
    return {**identity, 'flutterNoticesSha256': actual_hash,
            'compressedFlutterNoticesSha256': sha256(compressed),
            'dependencyManifestSha256': after['dependency-manifest.json'],
            'licenseChecksumManifestSha256': sha256((directory / 'SHA256SUMS').read_bytes()),
            'checksumFilesVerified': len(after), 'correspondingSourceArchives': len(current['corresponding_sources']),
            'stagingUpdated': changed, 'committedLicenseBaselineModified': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-notices', required=True, type=Path)
    parser.add_argument('--staged-licenses', required=True, type=Path)
    parser.add_argument('--project-root', type=Path, default=ROOT)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    result = synchronize_notices(args.app_notices, args.staged_licenses, args.project_root,
                                 verify_only=args.verify_only)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, EOFError) as error:
        raise SystemExit(f'Release notices failed: {error}') from error
