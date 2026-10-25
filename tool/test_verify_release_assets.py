#!/usr/bin/env python3
"""Focused synthetic report/hash fixtures; does not build or run any product."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('verify-release-assets.py')
SPEC = importlib.util.spec_from_file_location('verify_release_assets', SCRIPT)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
COMMIT = 'a' * 40


class ReleaseAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='portly-release-assets-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = '0.5.1'
        self.mac = f'Portly-{self.version}-macOS-arm64'
        self.source = f'Portly-{self.version}-source.zip'
        self.write(self.source, b'synthetic source fixture')
        for suffix in ('.dmg', '.zip'):
            self.write(self.mac + suffix, f'synthetic mac {suffix}'.encode())
        for arch in ('x64', 'arm64'):
            base = self.base(arch)
            for suffix in ('-setup.exe', '-portable.zip'):
                self.write(base + suffix, f'synthetic {arch} {suffix}'.encode())
            self.json(base + '-manifest.json', {'product': 'Portly', 'version': self.version,
                                               'architecture': arch, 'sourceCommit': COMMIT})
            smoke = {key: True for key in ('passed', 'installed', 'nativePayloadVerified',
                     'windowCreated', 'gracefulExit', 'databaseClosed', 'uninstalled',
                     'userDataPreserved', 'appHasExitedBeforeCleanup')}
            smoke.update(architecture=arch, forcedCleanup=False, appExitCode=0,
                         appExitCodeHex='0x00000000', error=None,
                         installerSha256=self.hash(base + '-setup.exe'))
            self.json(base + '-smoke.json', smoke)
        self.json(self.mac + '.verification.json', {
            'architecture': 'arm64', 'dmgMountVerified': True, 'dmgDetached': True,
            'zipExtractionVerified': True,
            'app': {'version': self.version, 'strictCodeSignature': True, 'machOCount': 1,
                    'machO': [{'path': 'Contents/MacOS/Portly', 'architectures': ['arm64'], 'sha256': 'b' * 64}]},
            'artifacts': [{'file': self.mac + suffix, 'bytes': (self.root / (self.mac + suffix)).stat().st_size,
                           'sha256': self.hash(self.mac + suffix)} for suffix in ('.dmg', '.zip')],
        })
        self.refresh_sidecars()

    def base(self, arch):
        return f'Portly-{self.version}-windows-{arch}'

    def write(self, name, content):
        (self.root / name).write_bytes(content)

    def json(self, name, value):
        self.write(name, (json.dumps(value, indent=2) + '\n').encode())

    def read_json(self, name):
        return json.loads((self.root / name).read_text())

    def hash(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest()

    def refresh_sidecars(self):
        for name in (self.source, self.mac + '.dmg', self.mac + '.zip'):
            self.write(name + '.sha256', f'{self.hash(name)}  {name}\n'.encode())
        for arch in ('x64', 'arm64'):
            base = self.base(arch)
            members = [base + suffix for suffix in ('-setup.exe', '-portable.zip', '-manifest.json')]
            self.write(base + '-SHA256SUMS.txt', ''.join(f'{self.hash(name)}  {name}\n' for name in members).encode())

    def verify(self, **kwargs):
        return VERIFIER.verify_release_assets(self.root, **kwargs)

    def reject(self, reason):
        with self.assertRaisesRegex(VERIFIER.ReleaseValidationError, reason):
            self.verify()

    def test_complete_release_generates_full_aggregate_and_is_idempotent(self):
        result = self.verify(expected_version=self.version, expected_commit=COMMIT)
        self.assertEqual(result['requiredAssetsVerified'], 17)
        before = (self.root / 'SHA256SUMS').read_bytes()
        self.assertEqual(len(before.splitlines()), 17)
        self.verify()
        self.assertEqual((self.root / 'SHA256SUMS').read_bytes(), before)

    def test_existing_positional_directory_cli_is_compatible(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('17 required assets', result.stdout)

    def test_read_only_mode_never_creates_aggregate(self):
        self.verify(write_checksums=False)
        self.assertFalse((self.root / 'SHA256SUMS').exists())

    def test_smoke_architecture_must_match_filename(self):
        name = self.base('arm64') + '-smoke.json'
        smoke = self.read_json(name)
        smoke['architecture'] = 'x64'
        self.json(name, smoke)
        self.reject('smoke architecture mismatch')

    def test_smoke_must_reference_actual_installer_hash(self):
        name = self.base('x64') + '-smoke.json'
        smoke = self.read_json(name)
        smoke['installerSha256'] = self.hash(self.base('arm64') + '-setup.exe')
        self.json(name, smoke)
        self.reject('installerSha256')

    def test_exit_must_be_numeric_zero_and_hex_must_not_disagree(self):
        name = self.base('x64') + '-smoke.json'
        original = self.read_json(name)
        for value in (-1073740771, 1, False, '0', None):
            with self.subTest(value=value):
                self.json(name, {**original, 'appExitCode': value})
                self.reject('numeric code 0')
        self.json(name, {**original, 'appExitCodeHex': '0xC000041D'})
        self.reject('exit code fields disagree')

    def test_every_required_smoke_boolean_must_be_exactly_true(self):
        name = self.base('x64') + '-smoke.json'
        original = self.read_json(name)
        for key in ('passed', 'installed', 'nativePayloadVerified', 'windowCreated', 'gracefulExit',
                    'databaseClosed', 'uninstalled', 'userDataPreserved', 'appHasExitedBeforeCleanup'):
            for value in (False, 1, 'true', None):
                with self.subTest(key=key, value=value):
                    self.json(name, {**original, key: value})
                    self.reject(f'did not confirm {key}')

    def test_forced_cleanup_or_report_error_is_rejected(self):
        name = self.base('x64') + '-smoke.json'
        original = self.read_json(name)
        self.json(name, {**original, 'forcedCleanup': True})
        self.reject('forced cleanup')
        self.json(name, {**original, 'error': 'startup error'})
        self.reject('contains an error')

    def test_windows_manifest_version_architecture_and_commit_are_bound(self):
        name = self.base('arm64') + '-manifest.json'
        original = self.read_json(name)
        for field, value, message in [('version', '0.5.0', 'product/version'),
                                       ('architecture', 'x64', 'manifest architecture'),
                                       ('sourceCommit', 'uncommitted', 'valid source commit'),
                                       ('sourceCommit', 'c' * 40, 'different source commits')]:
            with self.subTest(field=field):
                self.json(name, {**original, field: value})
                self.refresh_sidecars()
                self.reject(message)

    def test_mac_verification_report_is_required(self):
        (self.root / (self.mac + '.verification.json')).unlink()
        self.reject('Missing release files')

    def test_mac_flags_and_strict_signature_are_required(self):
        name = self.mac + '.verification.json'
        original = self.read_json(name)
        for flag in ('dmgMountVerified', 'dmgDetached', 'zipExtractionVerified'):
            with self.subTest(flag=flag):
                self.json(name, {**original, flag: False})
                self.reject(f'did not confirm {flag}')
        original['app']['strictCodeSignature'] = False
        self.json(name, original)
        self.reject('strict code signature')

    def test_mac_version_and_arm64_macho_inventory_are_required(self):
        name = self.mac + '.verification.json'
        original = self.read_json(name)
        self.json(name, {**original, 'architecture': 'x64'})
        self.reject('report architecture')
        for mutation, message in [('version', 'app version'), ('arch', 'exclusively arm64'),
                                  ('empty', 'invalid Mach-O'), ('count', 'invalid Mach-O')]:
            with self.subTest(mutation=mutation):
                report = json.loads(json.dumps(original))
                if mutation == 'version': report['app']['version'] = '0.5.0'
                if mutation == 'arch': report['app']['machO'][0]['architectures'] = ['arm64', 'x86_64']
                if mutation == 'empty': report['app']['machO'] = []
                if mutation == 'count': report['app']['machOCount'] = 99
                self.json(name, report)
                self.reject(message)

    def test_mac_report_must_bind_actual_hash_size_and_exact_two_artifacts(self):
        name = self.mac + '.verification.json'
        original = self.read_json(name)
        for mutation, message in [('hash', 'artifact hash differs'), ('size', 'artifact size differs'),
                                  ('name', 'filename mismatch'), ('duplicate', 'filename mismatch'),
                                  ('missing', 'exactly its DMG and ZIP')]:
            with self.subTest(mutation=mutation):
                report = json.loads(json.dumps(original))
                if mutation == 'hash': report['artifacts'][0]['sha256'] = '0' * 64
                if mutation == 'size': report['artifacts'][0]['bytes'] += 1
                if mutation == 'name': report['artifacts'][0]['file'] = 'Portly-0.5.0-macOS-arm64.dmg'
                if mutation == 'duplicate': report['artifacts'][1] = report['artifacts'][0]
                if mutation == 'missing': report['artifacts'].pop()
                self.json(name, report)
                self.reject(message)

    def test_old_version_and_unknown_assets_are_not_uploaded(self):
        for name in ('Portly-0.5.0-windows-x64-setup.exe', 'unexpected.txt'):
            with self.subTest(name=name):
                self.write(name, b'unexpected')
                self.reject('Unexpected or mixed-version')
                (self.root / name).unlink()

    def test_second_version_source_is_rejected(self):
        self.write('Portly-0.5.0-source.zip', b'old source')
        self.reject('Exactly one')

    def test_bad_binary_or_incomplete_sidecar_is_rejected(self):
        name = self.base('x64') + '-setup.exe'
        self.write(name, b'changed installer')
        self.reject('Checksum mismatch')
        self.refresh_sidecars()
        sidecar = self.root / (self.base('x64') + '-SHA256SUMS.txt')
        sidecar.write_text(sidecar.read_text().splitlines()[0] + '\n')
        self.reject('Checksum inventory differs')

    def test_existing_bad_aggregate_is_not_silently_replaced(self):
        self.verify()
        path = self.root / 'SHA256SUMS'
        path.write_text(path.read_text().replace(self.hash(self.source), '0' * 64))
        before = path.read_bytes()
        self.reject('Checksum mismatch')
        self.assertEqual(path.read_bytes(), before)

    def test_explicit_workflow_version_and_commit_must_match(self):
        with self.assertRaisesRegex(VERIFIER.ReleaseValidationError, 'differs from expected'):
            self.verify(expected_version='0.5.0')
        with self.assertRaisesRegex(VERIFIER.ReleaseValidationError, 'expected build commit'):
            self.verify(expected_commit='d' * 40)


if __name__ == '__main__':
    unittest.main()
