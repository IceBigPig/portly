#!/usr/bin/env python3
"""Build/thin, sign and verify an Apple Silicon drag-to-Applications release."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import gzip
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from sync_release_notices import synchronize_notices
MACH_MAGICS = {bytes.fromhex(value) for value in (
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca", "cffaedfe", "feedfacf", "cefaedfe", "feedface",
)}


def run(*args: object, capture: bool = False, env: dict[str, str] | None = None) -> str:
    command = [str(arg) for arg in args]
    result = subprocess.run(command, cwd=ROOT, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode("utf-8", errors="replace") if capture else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def mach_files(app: Path) -> list[Path]:
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as source:
            if source.read(4) in MACH_MAGICS:
                binaries.append(path)
    return sorted(binaries)


def app_info(app: Path) -> dict:
    with (app / "Contents/Info.plist").open("rb") as source:
        return plistlib.load(source)


def read_entitlements(app: Path) -> dict:
    raw = run("codesign", "-d", "--entitlements", ":-", app, capture=True).strip()
    return plistlib.loads(raw.encode()) if raw else {}


def flutter_assets(app: Path) -> dict:
    assets = app / "Contents/Frameworks/App.framework/Resources/flutter_assets"
    if not assets.is_dir():
        raise RuntimeError("Flutter asset directory is missing")
    files = [{"path": path.relative_to(assets).as_posix(), "bytes": path.stat().st_size,
              "sha256": sha256(path)} for path in sorted(assets.rglob("*")) if path.is_file()]
    manifest = json.dumps(files, ensure_ascii=False, separators=(",", ":")).encode()
    return {"files": len(files), "manifestSha256": hashlib.sha256(manifest).hexdigest()}


def verify_notices(app: Path) -> dict:
    notices = app / "Contents/Resources/Notices"
    required = ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "third_party_licenses")
    if any(not (notices / name).exists() for name in required):
        raise RuntimeError("The packaged application is missing a required license/NOTICE/source directory")
    third_party = notices / "third_party_licenses"
    checked = 0
    for line in (third_party / "SHA256SUMS").read_text().splitlines():
        digest, relative = line.split("  ", 1)
        path = third_party / relative
        if not path.resolve().is_relative_to(third_party.resolve()) or not path.is_file():
            raise RuntimeError(f"Invalid packaged license checksum path: {relative}")
        if sha256(path) != digest:
            raise RuntimeError(f"Packaged license checksum mismatch: {relative}")
        checked += 1
    manifest = json.loads((third_party / "dependency-manifest.json").read_text())
    sources = manifest.get("corresponding_sources", [])
    if len(sources) < 3 or any(not (third_party / item["file"]).is_file() for item in sources):
        raise RuntimeError("Corresponding LGPL source archives are missing")
    compressed = app / "Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z"
    decoded_hash = hashlib.sha256(gzip.decompress(compressed.read_bytes())).hexdigest()
    if decoded_hash != sha256(third_party / "FLUTTER-NOTICES.txt") or decoded_hash != manifest.get("flutter_notices_sha256"):
        raise RuntimeError("Flutter license text does not match this app's NOTICES.Z; regenerate with collect_licenses.py")
    return {"checksumFilesVerified": checked, "correspondingSourceArchives": len(sources),
            "flutterNoticesSha256": decoded_hash,
            "rootNotices": {name: sha256(notices / name) for name in required if (notices / name).is_file()}}


def verify_app(app: Path, version: str) -> dict:
    run("codesign", "--verify", "--deep", "--strict", app)
    info = app_info(app)
    if info.get("CFBundleShortVersionString") != version:
        raise RuntimeError(f"App version differs from requested {version}: {info.get('CFBundleShortVersionString')}")
    main = app / "Contents/MacOS" / info["CFBundleExecutable"]
    binaries = mach_files(app)
    if main not in binaries or not any("App.framework" in str(path) for path in binaries):
        raise RuntimeError("Main executable or Flutter AOT App.framework is missing")
    results = []
    declared_min = info.get("LSMinimumSystemVersion", "0")
    def version_tuple(value: str) -> tuple[int, ...]:
        return tuple(int(part) for part in value.split(".")) + (0,) * (4 - len(value.split(".")))
    for path in binaries:
        archs = run("lipo", "-archs", path, capture=True).strip().split()
        if archs != ["arm64"]:
            raise RuntimeError(f"Non-arm64 payload: {path}: {archs}")
        run("codesign", "--verify", "--strict", path)
        build = run("xcrun", "vtool", "-show-build", path, capture=True)
        minima = re.findall(r"\bminos\s+([0-9.]+)", build)
        if any(version_tuple(minimum) > version_tuple(declared_min) for minimum in minima):
            raise RuntimeError(f"{path} requires {minima}, above Info.plist minimum {declared_min}")
        results.append({"path": str(path.relative_to(app)), "architectures": archs,
                        "sha256": sha256(path), "minimumMacOS": minima})
    return {"version": version, "buildNumber": str(info.get("CFBundleVersion", "")),
            "bundleIdentifier": info.get("CFBundleIdentifier"), "minimumMacOS": declared_min,
            "entitlements": read_entitlements(app), "machOCount": len(results), "machO": results,
            "strictCodeSignature": True, "flutterAssets": flutter_assets(app), "notices": verify_notices(app)}


def thin_and_sign(app: Path, entitlements_file: Path) -> None:
    for path in mach_files(app):
        archs = run("lipo", "-archs", path, capture=True).strip().split()
        if "arm64" not in archs:
            raise RuntimeError(f"Required arm64 slice is absent: {path}: {archs}")
        if archs != ["arm64"]:
            temporary = path.with_name(path.name + ".arm64-tmp")
            mode = stat.S_IMODE(path.stat().st_mode)
            run("lipo", path, "-thin", "arm64", "-output", temporary)
            temporary.chmod(mode)
            temporary.replace(path)
    # A packaged native asset may require a newer OS than Runner's build setting.
    # Declare the actual effective minimum instead of advertising an app that the
    # dynamic linker cannot load. Only the temporary staging plist is adjusted.
    info_path = app / "Contents/Info.plist"
    info = app_info(app)
    minima = [info.get("LSMinimumSystemVersion", "0")]
    for path in mach_files(app):
        build = run("xcrun", "vtool", "-show-build", path, capture=True)
        minima.extend(re.findall(r"\bminos\s+([0-9.]+)", build))
    effective = max(minima, key=lambda value: tuple(int(part) for part in value.split(".")) + (0,) * (4 - len(value.split("."))))
    if effective != info.get("LSMinimumSystemVersion"):
        info["LSMinimumSystemVersion"] = effective
        with info_path.open("wb") as target:
            plistlib.dump(info, target)
    # Sign leaves before bundle containers. No --deep signing and no Developer
    # ID/keychain access: this is an explicit, reproducible local ad-hoc package.
    for path in sorted(mach_files(app), key=lambda item: len(item.parts), reverse=True):
        run("codesign", "--force", "--sign", "-", "--timestamp=none",
            "--preserve-metadata=entitlements,flags,identifier", path)
    bundles = [path for path in app.rglob("*") if not path.is_symlink()
               and path.is_dir() and path.suffix in (".framework", ".app", ".xpc")]
    for bundle in sorted(bundles, key=lambda item: len(item.parts), reverse=True):
        run("codesign", "--force", "--sign", "-", "--timestamp=none",
            "--preserve-metadata=entitlements,flags,identifier", bundle)
    run("codesign", "--force", "--sign", "-", "--timestamp=none",
        "--entitlements", entitlements_file, app)


def install_notices(app: Path, extras: list[Path]) -> list[str]:
    candidates = [ROOT / "LICENSE", ROOT / "NOTICE", ROOT / "THIRD_PARTY_NOTICES.md", ROOT / "third_party_licenses", *extras]
    missing = [str(path.relative_to(ROOT)) for path in candidates[:4] if not path.exists()]
    if missing:
        raise RuntimeError(f"Required release license material is missing: {missing}")
    seen_sources = set()
    included = []
    destination = app / "Contents/Resources/Notices"
    for source in candidates:
        if source.resolve() in seen_sources:
            continue
        seen_sources.add(source.resolve())
        if not source.exists():
            raise RuntimeError(f"Notice input is missing: {source}")
        destination.mkdir(parents=True, exist_ok=True)
        target = destination / source.name
        if target.exists():
            raise RuntimeError(f"Duplicate packaged notice name: {source.name}")
        if source.is_dir():
            shutil.copytree(source, target, symlinks=True)
        else:
            shutil.copy2(source, target)
        included.append(source.name)
    return included


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("macOS packaging requires macOS and Xcode command line tools")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64"], default="arm64")
    parser.add_argument("--version", help="Defaults to pubspec.yaml's release version")
    parser.add_argument("--source-app", type=Path, help="Use an audited main-entry .app instead of building")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "releases")
    parser.add_argument("--include-notice", type=Path, action="append", default=[])
    parser.add_argument("--overwrite", action="store_true", help="Replace artifacts with this exact version")
    args = parser.parse_args()
    package_version = re.search(r"^version:\s*([^\s#]+)", (ROOT / "pubspec.yaml").read_text(), re.MULTILINE)
    if package_version is None:
        raise RuntimeError("pubspec.yaml has no version")
    declared, _, number = package_version.group(1).partition("+")
    version = args.version or declared
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("Version must be x.y.z, with an optional prerelease suffix")
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    basename = f"Portly-{version}-macOS-arm64"
    targets = [output / f"{basename}{suffix}" for suffix in
               (".dmg", ".zip", ".dmg.sha256", ".zip.sha256", ".verification.json")]
    if not args.overwrite and any(path.exists() for path in targets):
        raise RuntimeError("Artifacts already exist; inspect them first or pass --overwrite")
    if args.source_app:
        source_app = args.source_app.expanduser().resolve()
        build_mode = "audited-prebuilt-main-app"
    else:
        env = os.environ.copy()
        env["FLUTTER_XCODE_ARCHS"] = "arm64"
        run(ROOT / "tool/build-macos.sh", "--target", "lib/main.dart", "--build-name", version,
            "--build-number", number or "1", env=env)
        source_app = ROOT / "build/macos/Build/Products/Release/Portly.app"
        build_mode = "lib/main.dart with invocation-local FLUTTER_XCODE_ARCHS=arm64"
    if not source_app.is_dir() or source_app.suffix != ".app":
        raise RuntimeError(f"Missing source .app: {source_app}")
    run("codesign", "--verify", "--deep", "--strict", source_app)
    source_info = app_info(source_app)
    if source_info.get("CFBundleShortVersionString") != version:
        raise RuntimeError("Source .app version does not match requested artifact version")
    source_entitlements = read_entitlements(source_app)
    source_assets = flutter_assets(source_app)
    with tempfile.TemporaryDirectory(prefix="portly-macos-package-") as temporary:
        work = Path(temporary)
        image = work / "image"
        image.mkdir()
        staged = image / "Portly.app"
        run("ditto", source_app, staged)
        notices = install_notices(staged, [path.expanduser().resolve() for path in args.include_notice])
        as_built_notices = synchronize_notices(
            staged / 'Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z',
            staged / 'Contents/Resources/Notices/third_party_licenses', ROOT,
        )
        entitlement_file = work / "entitlements.plist"
        with entitlement_file.open("wb") as target:
            plistlib.dump(source_entitlements, target)
        thin_and_sign(staged, entitlement_file)
        staged_result = verify_app(staged, version)
        if staged_result["entitlements"] != source_entitlements:
            raise RuntimeError("Main executable entitlements changed")
        if staged_result["flutterAssets"] != source_assets:
            raise RuntimeError("Flutter assets changed from the audited source app")
        (image / "Applications").symlink_to("/Applications", target_is_directory=True)
        temporary_zip, temporary_dmg = work / f"{basename}.zip", work / f"{basename}.dmg"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", staged, temporary_zip)
        extracted = work / "zip-verification"
        extracted.mkdir()
        run("ditto", "-x", "-k", temporary_zip, extracted)
        zip_result = verify_app(extracted / "Portly.app", version)
        if zip_result != staged_result:
            raise RuntimeError("ZIP extraction differs from signed staging app")
        run("hdiutil", "create", "-quiet", "-volname", "Portly", "-fs", "HFS+", "-format", "UDZO",
            "-srcfolder", image, temporary_dmg)
        run("hdiutil", "verify", "-quiet", temporary_dmg)
        mount = work / "mounted"
        mount.mkdir()
        device = None
        try:
            attach = plistlib.loads(run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount,
                                       "-plist", temporary_dmg, capture=True).encode())
            device = next(item["dev-entry"] for item in attach["system-entities"]
                          if item.get("mount-point") and Path(item["mount-point"]).resolve() == mount.resolve())
            if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                raise RuntimeError("DMG Applications shortcut is missing or incorrect")
            dmg_result = verify_app(mount / "Portly.app", version)
            if dmg_result != staged_result:
                raise RuntimeError("Mounted DMG differs from signed staging app")
        finally:
            if device:
                run("hdiutil", "detach", "-quiet", device)
            elif os.path.ismount(mount):
                run("hdiutil", "detach", "-quiet", mount)
        # Publish only fully verified artifacts. The source .app is never modified.
        shutil.copy2(temporary_dmg, targets[0])
        shutil.copy2(temporary_zip, targets[1])
        artifacts = []
        for payload, checksum in ((targets[0], targets[2]), (targets[1], targets[3])):
            digest = sha256(payload)
            checksum.write_text(f"{digest}  {payload.name}\n")
            artifacts.append({"file": payload.name, "bytes": payload.stat().st_size, "sha256": digest})
        report = {"generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "buildMode": build_mode,
                  "sourceApp": source_app.name, "sourceDeclaredMinimumMacOS": source_info.get("LSMinimumSystemVersion"),
                  "architecture": "arm64", "signing": "ad-hoc",
                  "developerIdSigned": False, "notarized": False, "packagedNotices": notices,
                  "asBuiltNotices": as_built_notices,
                  "dmgMountVerified": True, "dmgDetached": True, "zipExtractionVerified": True,
                  "applicationShortcut": "/Applications", "app": staged_result, "artifacts": artifacts}
        targets[4].write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"verification": str(targets[4]), "artifacts": artifacts}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, OSError, RuntimeError, StopIteration) as error:
        raise SystemExit(f"macOS packaging failed: {error}") from error
