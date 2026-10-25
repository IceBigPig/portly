#!/usr/bin/env python3
"""Collect actual locked package licenses and LGPL sources without Flutter CLI.

Run flutter pub get first. No third-party code is executed by this script.
All generated manifests use public URLs and relative names, never cache paths.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import sys
import tarfile
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname, urlopen

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'third_party_licenses'
UPSTREAM_URL = ('https://codeload.github.com/sigrokproject/libserialport/'
                'tar.gz/refs/tags/libserialport-0.1.1')
UPSTREAM_SHA = '4e3573e3bdbb6b0a872f32c4826d1b6b630dcc3eeb5f05d0501bb79d738a09ea'
UPSTREAM_COMMIT = '348a6d353af8ac142f68fbf9fe0f4d070448d945'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_uri_path(uri):
    parsed = urlparse(uri)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise SystemExit('Expected a local file URI in package_config.json')
    return Path(url2pathname(parsed.path))


def fetch(url):
    # Some python.org macOS installs lack their own CA bundle. Keep TLS
    # verification enabled and use macOS's trusted CA file when appropriate.
    cafile = '/etc/ssl/cert.pem' if sys.platform == 'darwin' and not os.environ.get('SSL_CERT_FILE') and Path('/etc/ssl/cert.pem').is_file() else None
    return urlopen(url, timeout=30, context=ssl.create_default_context(cafile=cafile))


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def locked_packages():
    # This intentionally parses only pub's generated lockfile structure.
    packages, current = {}, None
    for line in (ROOT / 'pubspec.lock').read_text().splitlines():
        name = re.fullmatch(r'  ([A-Za-z0-9_]+):', line)
        if name:
            current = packages.setdefault(name[1], {})
        elif current is not None:
            field = re.fullmatch(r'    (version|source|dependency): (.+)', line)
            if field:
                current[field[1]] = field[2].strip('"\'')
            archive_hash = re.fullmatch(r'      sha256: (.+)', line)
            if archive_hash:
                current['pub_archive_sha256'] = archive_hash[1].strip('"\'')
    return packages


def license_label(text, name):
    if name == 'flutter_libserialport':
        return 'MIT wrapper; LGPL-3.0-or-later bundled native library'
    if name == 'sky_engine':
        return 'Flutter engine bundled notices (multiple licenses)'
    if 'GNU LESSER GENERAL PUBLIC LICENSE' in text:
        return 'LGPL-3.0-or-later' if name == 'libserialport' else 'LGPL (see text)'
    if 'Apache License' in text and 'Version 2.0' in text:
        return 'Apache-2.0'
    if 'Permission is hereby granted, free of charge' in text:
        return 'MIT'
    if 'Redistribution and use in source and binary forms' in text:
        return 'BSD-3-Clause' if ('endorse' in text or 'promote' in text) else 'BSD-2-Clause'
    return 'See original license text'


def deterministic_source_archive(source, name, destination):
    """Complete resolved package tree, normalized metadata, no machine paths."""
    with destination.open('wb') as stream:
        with gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as tar:
                for path in sorted(source.rglob('*')):
                    relative = path.relative_to(source)
                    if any(part in {'.dart_tool', '.git', 'build'} for part in relative.parts):
                        continue  # Local generated artifacts are not package source.
                    if path.is_symlink():
                        raise SystemExit(f'Unexpected source symlink in {name}: {relative}')
                    if not path.is_file():
                        continue
                    content = path.read_bytes()
                    info = tarfile.TarInfo(f'{name}/{relative.as_posix()}')
                    info.size = len(content)
                    info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                    info.mtime = info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    tar.addfile(info, io.BytesIO(content))


def collect(args):
    config_path = ROOT / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    sdk = file_uri_path(config['flutterRoot'])
    locked = locked_packages()
    for name, version in {'flutter_libserialport': '0.6.0', 'libserialport': '0.3.0+1'}.items():
        if locked.get(name, {}).get('version') != version:
            raise SystemExit(f'Review/update the native and LGPL corresponding-source recipe before collecting changed dependency {name}; expected {version}')
    roots, packages = {}, []
    package_out = OUT / 'packages'
    if package_out.exists():
        shutil.rmtree(package_out)  # Only this script's generated license copies.
    for package in sorted(config['packages'], key=lambda p: p['name']):
        name = package['name']
        if name == 'portly':
            continue
        lock = locked.get(name)
        if lock is None:
            raise SystemExit(f'{name} is resolved but not locked')
        path = file_uri_path(urljoin(config_path.as_uri(), package['rootUri']))
        roots[name] = path
        if lock['source'] == 'hosted':
            version = re.search(r'^version:\s*[\'"]?([^\s\'"]+)',
                                (path / 'pubspec.yaml').read_text(), re.MULTILINE)
            if not version or version[1] != lock['version']:
                raise SystemExit(f'Resolved version mismatch for {name}')
        files = []
        for entry in sorted(path.rglob('*')):
            if not entry.is_file() or entry.is_symlink():
                continue
            if re.fullmatch(r'(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|OFL)([._-].*)?', entry.name, re.I):
                relative = entry.relative_to(path)
                target = package_out / f'{name}-{lock["version"]}' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(entry, target)
                files.append({'file': target.relative_to(OUT).as_posix(), 'sha256': digest(entry.read_bytes())})
        if not files and lock['source'] == 'sdk':
            target = package_out / f'{name}-{lock["version"]}' / 'LICENSE'
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(sdk / 'LICENSE', target)
            files.append({'file': target.relative_to(OUT).as_posix(), 'sha256': digest(target.read_bytes()), 'inherited_from': 'Flutter SDK LICENSE'})
        if not files:
            raise SystemExit(f'No license found for {name}')
        primary = next((f for f in files if Path(f['file']).name == 'LICENSE'), files[0])
        label = license_label((OUT / primary['file']).read_text(errors='replace'), name)
        packages.append({'name': name, **lock, 'license': label, 'license_files': files,
                         'source_url': f'https://pub.dev/packages/{name}/versions/{lock["version"]}' if lock['source'] == 'hosted' else 'https://github.com/flutter/flutter'})

    sources = OUT / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    upstream = sources / 'libserialport-0.1.1-upstream.tar.gz'
    if not upstream.exists():
        with fetch(UPSTREAM_URL) as response:
            upstream.write_bytes(response.read())
    if digest(upstream.read_bytes()) != UPSTREAM_SHA:
        raise SystemExit('Upstream libserialport archive hash mismatch')
    source_records = [{'component': 'macOS native libserialport', 'version': '0.1.1',
                       'file': upstream.relative_to(OUT).as_posix(), 'sha256': UPSTREAM_SHA,
                       'source_url': UPSTREAM_URL, 'upstream_tag': 'libserialport-0.1.1',
                       'upstream_commit': UPSTREAM_COMMIT, 'license': 'LGPL-3.0-or-later'}]
    for name in ('flutter_libserialport', 'libserialport'):
        version = locked[name]['version']
        archive = sources / f'{name}-{version}-resolved-source.tar.gz'
        deterministic_source_archive(roots[name], f'{name}-{version}', archive)
        source_records.append({'component': name, 'version': version,
                               'file': archive.relative_to(OUT).as_posix(), 'sha256': digest(archive.read_bytes()),
                               'pub_archive_sha256': locked[name]['pub_archive_sha256'],
                               'source_url': f'https://pub.dev/api/archives/{name}-{version}.tar.gz',
                               'license': 'MIT wrapper with LGPL-3.0-or-later native third_party/libserialport' if name == 'flutter_libserialport' else 'LGPL-3.0-or-later'})
    if args.verify_published_sources:
        verified = []
        for name in ('flutter_libserialport', 'libserialport'):
            version = locked[name]['version']
            url = f'https://pub.dev/api/archives/{name}-{version}.tar.gz'
            with fetch(url) as response:
                content = response.read()
            actual_hash = digest(content)
            if actual_hash != locked[name]['pub_archive_sha256']:
                raise SystemExit(f'Published archive hash differs from lockfile: {name}')
            count = 0
            published_files = set()
            with tarfile.open(fileobj=io.BytesIO(content)) as archive:
                for member in archive.getmembers():
                    if not member.isfile():
                        continue
                    relative = Path(member.name)
                    if relative.is_absolute() or '..' in relative.parts:
                        raise SystemExit('Unsafe published archive member')
                    if (roots[name] / relative).read_bytes() != archive.extractfile(member).read():
                        raise SystemExit(f'Cached package differs from published source: {name}/{relative}')
                    published_files.add(relative.as_posix())
                    count += 1
            cached_files = {p.relative_to(roots[name]).as_posix() for p in roots[name].rglob('*')
                            if p.is_file() and not any(part in {'.dart_tool', '.git', 'build'}
                                                     for part in p.relative_to(roots[name]).parts)}
            if cached_files != published_files:
                raise SystemExit(f'Resolved cache has files absent from the published source: {name}')
            verified.append({'package': name, 'version': version, 'source_url': url,
                             'published_archive_sha256': actual_hash,
                             'all_published_files_identical_to_resolved_cache': True,
                             'compared_file_count': count})
        write_json(sources / 'published-source-verification.json', verified)

    if args.verify_macos_pod:
        pod = ROOT / 'macos/Pods/libserialport'
        compared = []
        with tarfile.open(upstream) as archive:
            prefix = archive.getnames()[0] + '/'
            for filename in ('serialport.c', 'macosx.c', 'libserialport_internal.h', 'libserialport.h.in'):
                original = archive.extractfile(prefix + filename).read()
                actual = (pod / filename).read_bytes()
                if original != actual:
                    raise SystemExit(f'Installed macOS Pod differs from pinned tag: {filename}')
                compared.append({'file': filename, 'identical': True, 'sha256': digest(actual)})
        native = OUT / 'native/macos'
        native.mkdir(parents=True, exist_ok=True)
        for filename in ('config.h', 'libserialport.h'):
            shutil.copyfile(pod / filename, native / filename)
        spec = Path.home() / '.cocoapods/repos/trunk/Specs/3/b/3/libserialport/0.1.1/libserialport.podspec.json'
        shutil.copyfile(spec, native / 'libserialport-0.1.1.podspec.json')
        write_json(native / 'source-verification.json', {'upstream_tag': 'libserialport-0.1.1',
                   'upstream_commit': UPSTREAM_COMMIT, 'compared_compiled_inputs': compared,
                   'generated_inputs': ['config.h', 'libserialport.h'],
                   'note': 'C sources are unchanged; generated configuration/header and original Pod build recipe are supplied separately.'})

    notices = args.notices
    if notices:
        original = notices.read_bytes()
        decoded = gzip.decompress(original) if original.startswith(b'\x1f\x8b') else original
        (OUT / 'FLUTTER-NOTICES.txt').write_bytes(decoded)
    elif not (OUT / 'FLUTTER-NOTICES.txt').exists():
        raise SystemExit('Supply --notices from the built Release flutter_assets/NOTICES.Z')
    font = OUT / 'fonts/JetBrainsMono-OFL.txt'
    font.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'assets/fonts/OFL.txt', font)
    write_json(OUT / 'dependency-manifest.json', {'schema': 1,
               'scope': 'All resolved locked packages, including SDK/dev/build/platform alternatives; not a claim that all are present in each binary.',
               'pubspec_lock_sha256': digest((ROOT / 'pubspec.lock').read_bytes()),
               'flutter_version': config['flutterVersion'], 'dart_version': config['generatorVersion'],
               'packages': packages, 'corresponding_sources': source_records,
               'flutter_notices_sha256': digest((OUT / 'FLUTTER-NOTICES.txt').read_bytes())})
    table = ['# Resolved dependency license inventory', '',
             'Generated by `python3 tool/collect_licenses.py`; original text governs.', '',
             '| Package | Locked version | License | Original text |',
             '| --- | --- | --- | --- |']
    for p in packages:
        first = p['license_files'][0]['file']
        table.append(f'| {p["name"]} | {p["version"]} | {p["license"]} | [text]({first}) |')
    (OUT / 'DEPENDENCIES.md').write_text('\n'.join(table) + '\n')
    hashes = []
    for file in sorted(OUT.rglob('*')):
        if file.is_file() and file.name != 'SHA256SUMS':
            hashes.append(f'{digest(file.read_bytes())}  {file.relative_to(OUT).as_posix()}')
    (OUT / 'SHA256SUMS').write_text('\n'.join(hashes) + '\n')
    print(f'Collected {len(packages)} resolved packages and {len(source_records)} corresponding source archives.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notices', type=Path, help='Built Release NOTICES.Z (gzip) or decoded notice text')
    parser.add_argument('--verify-macos-pod', action='store_true', help='Compare the actual installed native Pod with the pinned upstream C inputs')
    parser.add_argument('--verify-published-sources', action='store_true', help='Download the two LGPL-related pub archives, verify lockfile SHA and compare every file with the resolved cache')
    collect(parser.parse_args())
