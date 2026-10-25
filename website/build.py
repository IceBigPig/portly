#!/usr/bin/env python3
"""Build the dependency-free GitHub Pages site and validate local references."""
import argparse
import json
import re
import shutil
import subprocess
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = 'https://github.com/IceBigPig/portly'
ASSET_SUFFIXES = {
    'mac-dmg': 'macOS-arm64.dmg', 'mac-zip': 'macOS-arm64.zip',
    'win-x64-setup': 'windows-x64-setup.exe', 'win-x64-zip': 'windows-x64-portable.zip',
    'win-arm64-setup': 'windows-arm64-setup.exe', 'win-arm64-zip': 'windows-arm64-portable.zip',
}


def latest_release():
    # curl uses the host trust store on macOS and is included on GitHub runners.
    response = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--retry', '2', '--max-time', '30', '--header', 'Accept: application/vnd.github+json', 'https://api.github.com/repos/IceBigPig/portly/releases/latest'], check=True, capture_output=True, text=True)
    release = json.loads(response.stdout)
    version = release['tag_name']
    if not re.fullmatch(r'v\d+\.\d+\.\d+', version) or release.get('draft') or release.get('prerelease'):
        raise ValueError('Expected a public stable release')
    files = {asset['name']: asset['browser_download_url'] for asset in release['assets']}
    assets = {key: files[f'Portly-{version[1:]}-{suffix}'] for key, suffix in ASSET_SUFFIXES.items()}
    return {'version': version, 'url': release['html_url'], 'published_at': release['published_at'], 'assets': assets}


class ValidateHTML(HTMLParser):
    def __init__(self, directory):
        super().__init__(convert_charrefs=True)
        self.directory = directory
        self.ids = set()
        self.anchors = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            if attrs['id'] in self.ids:
                raise ValueError(f'Duplicate id: {attrs["id"]}')
            self.ids.add(attrs['id'])
        for key in ['src', 'href']:
            value = attrs.get(key, '')
            if value.startswith('#'):
                self.anchors.append(value[1:])
            elif value.startswith('./'):
                if not (self.directory / value.split('?')[0]).is_file():
                    raise ValueError(f'Missing local asset: {value}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT.parent / 'dist' / 'website')
    parser.add_argument('--refresh-release', action='store_true', help='Resolve the latest published release during CI')
    args = parser.parse_args()
    output = args.output.resolve()
    # Never delete an arbitrary caller-supplied directory or touch the Flutter web project.
    if output == ROOT or ROOT in output.parents or output == ROOT.parent:
        raise ValueError('Build output must be outside website source and repository root')
    output.mkdir(parents=True, exist_ok=True)
    release = latest_release() if args.refresh_release else json.loads((ROOT / 'release.json').read_text())
    version = release['version']
    if not re.fullmatch(r'v\d+\.\d+\.\d+', version):
        raise ValueError('Invalid release version')
    prefix = f'{REPO}/releases/download/{version}/'
    for key in ASSET_SUFFIXES:
        if not release['assets'][key].startswith(prefix):
            raise ValueError(f'Invalid download destination: {key}')
    for filename in ['index.html', 'styles.css', 'app.js', 'tool-core.mjs', 'robots.txt', 'sitemap.xml', '.nojekyll']:
        shutil.copy2(ROOT / filename, output / filename)
    shutil.copytree(ROOT / 'assets', output / 'assets', dirs_exist_ok=True)
    (output / 'release.json').write_text(json.dumps(release, ensure_ascii=False, indent=2) + '\n')
    html = (output / 'index.html').read_text()
    html = re.sub(r'(<span data-version>)[^<]+', lambda match: match[1] + version, html)
    for key, url in release['assets'].items():
        html = re.sub(r'(data-asset="' + re.escape(key) + r'"\s+href=")[^"]+', lambda match: match[1] + url, html)
    (output / 'index.html').write_text(html)
    validator = ValidateHTML(output)
    validator.feed(html)
    for anchor in validator.anchors:
        if anchor and anchor not in validator.ids:
            raise ValueError(f'Missing anchor: #{anchor}')
    print(f'Built Portly {version}: {output}')
    print(f'Validated {len(validator.ids)} unique IDs, local assets, anchors and {len(release["assets"])} release downloads.')


if __name__ == '__main__':
    main()
