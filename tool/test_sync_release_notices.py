#!/usr/bin/env python3
"""Small disk fixtures for staging license binding; no Flutter or build needed."""
import gzip
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from sync_release_notices import sha256, synchronize_notices


class ReleaseNoticesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='portly-notice-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        self.sdk = self.root / 'sdk'
        (self.sdk / 'bin/cache').mkdir(parents=True)
        (self.sdk / 'packages/flutter').mkdir(parents=True)
        (self.sdk / 'bin/cache/flutter.version.json').write_text(json.dumps({
            'flutterVersion': '3.47.7', 'dartSdkVersion': '3.13.5',
            'frameworkRevision': 'fixture-framework', 'engineRevision': 'fixture-engine',
        }))
        self.hosted = self.root / 'fixture-package'
        self.hosted.mkdir()
        (self.hosted / 'pubspec.yaml').write_text('name: fixture\nversion: 1.2.3\n')
        lock = ('packages:\n  fixture:\n    source: hosted\n    version: "1.2.3"\n'
                '    description:\n      sha256: "' + 'a' * 64 + '"\n'
                '  flutter:\n    source: sdk\n    version: "0.0.0"\n')
        (self.project / 'pubspec.lock').write_text(lock)
        self.config = {'flutterRoot': self.sdk.as_uri(), 'flutterVersion': '3.47.7',
                       'generatorVersion': '3.13.5', 'packages': [
                           {'name': 'fixture', 'rootUri': self.hosted.as_uri()},
                           {'name': 'flutter', 'rootUri': (self.sdk / 'packages/flutter').as_uri()},
                           {'name': 'portly', 'rootUri': self.project.as_uri()},
                       ]}
        (self.project / '.dart_tool').mkdir()
        self.config_path = self.project / '.dart_tool/package_config.json'
        self.config_path.write_text(json.dumps(self.config))
        self.baseline = self.project / 'third_party_licenses'
        self.baseline.mkdir()
        self.stage = self.root / 'staging/third_party_licenses'
        self.old = b'Original upstream license text\n'
        self.new = b'Actual build license text\nUnicode: \xe8\xae\xb8\xe5\x8f\xaf\n'
        self.notices = self.root / 'NOTICES.Z'
        self.notices.write_bytes(gzip.compress(self.new, mtime=0))
        self.manifest = {'flutter_version': '3.47.7', 'dart_version': '3.13.5',
                         'pubspec_lock_sha256': sha256((self.project / 'pubspec.lock').read_bytes()),
                         'flutter_notices_sha256': sha256(self.old), 'packages': [
                             {'name': 'fixture', 'version': '1.2.3', 'source': 'hosted', 'pub_archive_sha256': 'a' * 64},
                             {'name': 'flutter', 'version': '0.0.0', 'source': 'sdk'},
                         ], 'corresponding_sources': []}
        (self.baseline / 'sources').mkdir()
        for i in range(3):
            name, source = f'sources/corresponding-{i}.tar.gz', f'source-{i}'.encode()
            (self.baseline / name).write_bytes(source)
            self.manifest['corresponding_sources'].append({'file': name, 'sha256': sha256(source)})
        (self.baseline / 'FLUTTER-NOTICES.txt').write_bytes(self.old)
        (self.baseline / 'LICENSE').write_bytes(b'Unchanged third-party license\n')
        (self.baseline / 'dependency-manifest.json').write_text(json.dumps(self.manifest, indent=2) + '\n')
        checksums = ''.join(f'{sha256(path.read_bytes())}  {path.relative_to(self.baseline).as_posix()}\n'
                            for path in sorted(self.baseline.rglob('*')) if path.is_file())
        (self.baseline / 'SHA256SUMS').write_text(checksums)
        shutil.copytree(self.baseline, self.stage)

    def tree(self, root):
        return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob('*') if p.is_file()}

    def sync(self, **kwargs):
        return synchronize_notices(self.notices, self.stage, self.project, **kwargs)

    def test_as_built_sync_only_changes_three_staging_files_and_verifies_again(self):
        baseline, before = self.tree(self.baseline), self.tree(self.stage)
        result = self.sync()
        after = self.tree(self.stage)
        self.assertEqual({p for p in before if before[p] != after[p]},
                         {'FLUTTER-NOTICES.txt', 'dependency-manifest.json', 'SHA256SUMS'})
        self.assertEqual(self.tree(self.baseline), baseline)
        self.assertEqual((self.stage / 'FLUTTER-NOTICES.txt').read_bytes(), self.new)
        manifest = json.loads(after['dependency-manifest.json'])
        self.assertEqual(manifest, {**self.manifest, 'flutter_notices_sha256': sha256(self.new)})
        self.assertTrue(result['stagingUpdated'])
        verified = self.sync(verify_only=True)
        self.assertFalse(verified['stagingUpdated'])
        self.assertEqual(verified['flutterNoticesSha256'], result['flutterNoticesSha256'])
        self.assertEqual(verified['checksumFilesVerified'], 6)
        self.assertEqual(self.tree(self.stage), after)

    def test_verify_only_rejects_unmatched_notices_without_writing(self):
        before = self.tree(self.stage)
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            self.sync(verify_only=True)
        self.assertEqual(self.tree(self.stage), before)

    def test_changed_lockfile_is_not_repaired_by_notice_sync(self):
        (self.project / 'pubspec.lock').write_text('different lockfile')
        with self.assertRaisesRegex(RuntimeError, 'pubspec.lock differs'):
            self.sync()

    def test_different_resolved_flutter_and_actual_sdk_are_rejected(self):
        self.config['flutterVersion'] = '3.47.8'
        self.config_path.write_text(json.dumps(self.config))
        with self.assertRaisesRegex(RuntimeError, 'Resolved Flutter/Dart'):
            self.sync()
        self.config['flutterVersion'] = '3.47.7'
        self.config_path.write_text(json.dumps(self.config))
        path = self.sdk / 'bin/cache/flutter.version.json'
        path.write_text(json.dumps({'flutterVersion': '3.47.8', 'dartSdkVersion': '3.13.5'}))
        with self.assertRaisesRegex(RuntimeError, 'Actual Flutter SDK'):
            self.sync()

    def test_different_actual_package_version_is_rejected(self):
        (self.hosted / 'pubspec.yaml').write_text('version: 9.9.9\n')
        with self.assertRaisesRegex(RuntimeError, 'Actual resolved dependency'):
            self.sync()

    def test_tampered_original_sources_are_not_rehashed_into_a_pass(self):
        (self.stage / 'sources/corresponding-0.tar.gz').write_bytes(b'tampered')
        before = self.tree(self.stage)
        with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
            self.sync()
        self.assertEqual(self.tree(self.stage), before)

    def test_committed_baseline_is_never_mutated(self):
        before = self.tree(self.baseline)
        with self.assertRaisesRegex(RuntimeError, 'staging copy'):
            synchronize_notices(self.notices, self.baseline, self.project)
        self.assertEqual(self.tree(self.baseline), before)

    def test_invalid_or_empty_gzip_is_rejected_without_writes(self):
        before = self.tree(self.stage)
        for content in (b'not gzip', gzip.compress(b'', mtime=0)):
            self.notices.write_bytes(content)
            with self.assertRaises(RuntimeError):
                self.sync()
        self.assertEqual(self.tree(self.stage), before)


if __name__ == '__main__':
    unittest.main()
