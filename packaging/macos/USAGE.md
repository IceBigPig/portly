# macOS arm64 packaging

Run on macOS with Xcode, Flutter, CocoaPods, and Python 3 available:

```sh
./tool/package-macos.sh --arch arm64 --version 0.5.0 --output-dir releases
```

The default path builds `lib/main.dart` in Release mode. It passes `FLUTTER_XCODE_ARCHS=arm64` only to that invocation; it does not change Flutter's global configuration. Cached engine and FFI frameworks are also checked and thinned, so every shipped Mach-O must contain only `arm64`.

An already audited main application can be packaged without another Flutter build:

```sh
./tool/package-macos.sh --source-app releases/Portly.app --arch arm64 --version 0.5.0 --output-dir releases
```

This option trusts the caller to choose the main application, rather than a pressure-test harness that shares the same bundle name. The source application's version and strict signature are checked, and its contents are copied to temporary staging. The source application and running instances are never modified or terminated.

Artifacts are `Portly-VERSION-macOS-arm64.dmg`, `.zip`, a `.sha256` file for each, and `.verification.json`. The DMG contains `Portly.app` and an `Applications -> /Applications` shortcut. The ZIP contains the same signed `Portly.app`. Existing artifacts require an explicit `--overwrite` on a repeat run.

The packaging process preserves source application entitlements and signs Mach-O leaves, framework containers, and the outer application in that order. It verifies every executable, plugin, and FFI framework with `lipo`, `vtool`, and strict `codesign`; extracts and verifies the ZIP; creates and verifies the compressed DMG; mounts it read-only; verifies the mounted application and shortcut; then detaches the volume. Final artifacts are published only after these checks succeed.

The staged application's declared minimum macOS is raised, when necessary, to the highest `LC_BUILD_VERSION` minimum among its native payloads. For the current dependency set this is macOS 13.0, required by both `objective_c.framework` and `sqlite3.framework`; the verification report records both source and effective minima. This adjustment does not modify the source app or lower any native library's compatibility requirement.

These local packages use ad-hoc signatures. They are not signed with a Developer ID certificate or notarized by Apple. Public distribution with Developer ID and notarization requires a separately configured release-signing process; the verification report records the actual signing state.

Repository `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, and `third_party_licenses/` are required and are copied into `Portly.app/Contents/Resources/Notices` before signing. Additional notices can be supplied with repeated `--include-notice PATH`. The verification report lists included notice sources. Every entry of `third_party_licenses/SHA256SUMS` is checked, at least three corresponding LGPL source archives must exist, and the packaged Flutter license text must match both the dependency manifest and the actual decompressed `NOTICES.Z`. The same checks run against staging, the extracted ZIP, and the mounted DMG; Flutter assets are also compared to the audited source application.

A CI macOS job can call the same command after installing the pinned Flutter version and CocoaPods, then upload `releases/Portly-*-macOS-arm64.*`. Use an Apple Silicon runner for direct execution and smoke tests. A cross-built package's successful archive/signature checks alone do not constitute runtime testing on the target machine.
