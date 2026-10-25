#!/usr/bin/env python3
"""Verify one complete native release and bind reports to its actual artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


class ReleaseValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseValidationError(message)


def valid_digest(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r'[a-fA-F0-9]{64}', value) is not None


def load_report(path: Path) -> dict:
    report = json.loads(path.read_text(encoding='utf-8-sig'))
    require(isinstance(report, dict), f'Report must be a JSON object: {path.name}')
    return report


def verify_release_assets(directory: Path, *, expected_version: str | None = None,
                          expected_commit: str | None = None,
                          write_checksums: bool = True) -> dict:
    root = directory.resolve()
    entries = list(root.iterdir())
    require(all(path.is_file() and not path.is_symlink() for path in entries),
            'Release assets must be a flat directory of regular files')
    files = {path.name: path for path in entries if path.name != 'SHA256SUMS'}
    sources = [name for name in files if re.fullmatch(r'Portly-\d+\.\d+\.\d+-source.zip', name)]
    require(len(sources) == 1, 'Exactly one corresponding source archive is required')
    version = sources[0][len('Portly-'):-len('-source.zip')]
    if expected_version is not None:
        require(version == expected_version, f'Release version {version} differs from expected {expected_version}')
    mac_base = f'Portly-{version}-macOS-arm64'
    mac_report_name = mac_base + '.verification.json'
    expected = {sources[0], sources[0] + '.sha256', mac_base + '.dmg', mac_base + '.zip',
                mac_base + '.dmg.sha256', mac_base + '.zip.sha256', mac_report_name}
    for arch in ('x64', 'arm64'):
        base = f'Portly-{version}-windows-{arch}'
        expected.update(base + suffix for suffix in (
            '-portable.zip', '-setup.exe', '-manifest.json', '-smoke.json', '-SHA256SUMS.txt'))
    require(not expected - files.keys(), f'Missing release files: {sorted(expected - files.keys())}')
    require(not files.keys() - expected,
            f'Unexpected or mixed-version release files: {sorted(files.keys() - expected)}')

    hashes: dict[str, str] = {}

    def digest(name: str) -> str:
        if name not in hashes:
            value = hashlib.sha256()
            with files[name].open('rb') as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    value.update(chunk)
            hashes[name] = value.hexdigest()
        return hashes[name]

    def verify_checksum_file(path: Path, members: set[str]) -> None:
        found: set[str] = set()
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            if not line.strip():
                continue
            match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?(.+)', line)
            require(match is not None, f'Invalid checksum line in {path.name}')
            expected_hash, name = match.groups()
            require('/' not in name and '\\' not in name and name in files and name not in found,
                    f'Invalid or duplicate checksum member in {path.name}: {name}')
            require(digest(name) == expected_hash.lower(), f'Checksum mismatch: {name}')
            found.add(name)
        require(found == members, f'Checksum inventory differs in {path.name}')

    verify_checksum_file(files[sources[0] + '.sha256'], {sources[0]})
    for suffix in ('.dmg', '.zip'):
        verify_checksum_file(files[mac_base + suffix + '.sha256'], {mac_base + suffix})
    for arch in ('x64', 'arm64'):
        base = f'Portly-{version}-windows-{arch}'
        verify_checksum_file(files[base + '-SHA256SUMS.txt'],
                             {base + suffix for suffix in ('-portable.zip', '-setup.exe', '-manifest.json')})
    # Validate a pre-existing aggregate before rewriting; never hide altered
    # reports/binaries by silently replacing their earlier checksum evidence.
    if (root / 'SHA256SUMS').exists():
        verify_checksum_file(root / 'SHA256SUMS', expected)

    commits: set[str] = set()
    for arch in ('x64', 'arm64'):
        base = f'Portly-{version}-windows-{arch}'
        smoke = load_report(files[base + '-smoke.json'])
        require(smoke.get('architecture') == arch, f'Native smoke architecture mismatch: {arch}')
        for flag in ('passed', 'installed', 'nativePayloadVerified', 'windowCreated',
                     'gracefulExit', 'databaseClosed', 'uninstalled',
                     'userDataPreserved', 'appHasExitedBeforeCleanup'):
            require(smoke.get(flag) is True, f'Native installation did not confirm {flag}: {arch}')
        require(smoke.get('forcedCleanup') is False, f'Native installation used forced cleanup: {arch}')
        require(type(smoke.get('appExitCode')) is int and smoke['appExitCode'] == 0,
                f'Native application did not exit with numeric code 0: {arch}')
        if 'appExitCodeHex' in smoke:
            require(smoke['appExitCodeHex'] == '0x00000000', f'Native exit code fields disagree: {arch}')
        require(smoke.get('error') is None, f'Native installation report contains an error: {arch}')
        installer_hash = smoke.get('installerSha256')
        require(valid_digest(installer_hash) and installer_hash.lower() == digest(base + '-setup.exe'),
                f'Native smoke installerSha256 does not match actual setup.exe: {arch}')
        manifest = load_report(files[base + '-manifest.json'])
        require(manifest.get('product') == 'Portly' and manifest.get('version') == version,
                f'Windows manifest product/version mismatch: {arch}')
        require(manifest.get('architecture') == arch, f'Windows manifest architecture mismatch: {arch}')
        commit = manifest.get('sourceCommit')
        require(isinstance(commit, str) and re.fullmatch(r'[a-fA-F0-9]{40}', commit) is not None,
                f'Windows manifest lacks a valid source commit: {arch}')
        commits.add(commit.lower())
    require(len(commits) == 1, 'Windows manifests come from different source commits')
    commit = next(iter(commits))
    if expected_commit is not None:
        require(commit == expected_commit.lower(), 'Windows manifest source commit differs from expected build commit')

    mac = load_report(files[mac_report_name])
    require(mac.get('architecture') == 'arm64', 'macOS report architecture is not arm64')
    for flag in ('dmgMountVerified', 'dmgDetached', 'zipExtractionVerified'):
        require(mac.get(flag) is True, f'macOS report did not confirm {flag}')
    app = mac.get('app')
    require(isinstance(app, dict) and app.get('version') == version, 'macOS app version mismatch')
    require(app.get('strictCodeSignature') is True, 'macOS report did not confirm strict code signature')
    binaries = app.get('machO')
    require(isinstance(binaries, list) and len(binaries) > 0
            and type(app.get('machOCount')) is int and app['machOCount'] == len(binaries),
            'macOS report has an invalid Mach-O inventory')
    binary_paths = set()
    for binary in binaries:
        require(isinstance(binary, dict) and binary.get('architectures') == ['arm64'],
                'macOS Mach-O payload is not exclusively arm64')
        name = binary.get('path')
        require(isinstance(name, str) and name not in binary_paths and valid_digest(binary.get('sha256')),
                'macOS Mach-O inventory has invalid or duplicate members')
        binary_paths.add(name)
    artifacts = mac.get('artifacts')
    require(isinstance(artifacts, list) and len(artifacts) == 2,
            'macOS report must bind exactly its DMG and ZIP')
    mac_artifacts = set()
    for artifact in artifacts:
        require(isinstance(artifact, dict), 'macOS artifact report must be an object')
        name = artifact.get('file')
        require(isinstance(name, str) and name in {mac_base + '.dmg', mac_base + '.zip'} and name not in mac_artifacts,
                'macOS report artifact filename mismatch or duplicate')
        require(type(artifact.get('bytes')) is int and artifact['bytes'] == files[name].stat().st_size,
                f'macOS report artifact size differs: {name}')
        value = artifact.get('sha256')
        require(valid_digest(value) and value.lower() == digest(name),
                f'macOS report artifact hash differs: {name}')
        mac_artifacts.add(name)

    if write_checksums:
        lines = [f'{digest(name)}  {name}' for name in sorted(files)]
        (root / 'SHA256SUMS').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return {'version': version, 'sourceCommit': commit, 'requiredAssetsVerified': len(expected),
            'windowsSmokeBoundToInstallers': ['x64', 'arm64'],
            'macOSVerificationBoundToArtifacts': sorted(mac_artifacts)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--version', help='Require the current workflow release version')
    parser.add_argument('--source-commit', help='Require the current workflow Git commit')
    args = parser.parse_args()
    try:
        result = verify_release_assets(args.directory, expected_version=args.version,
                                       expected_commit=args.source_commit)
    except (OSError, ValueError, TypeError, KeyError, ReleaseValidationError) as error:
        raise SystemExit(f'Release asset verification failed: {error}') from error
    print(f'All {result["requiredAssetsVerified"]} required assets, native reports and artifact bindings verified for {result["version"]}')


if __name__ == '__main__':
    main()
