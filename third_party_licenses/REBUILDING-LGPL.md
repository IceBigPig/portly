# Rebuilding and replacing the LGPL components

The C libserialport library and the Dart `libserialport` package are licensed
under LGPL-3.0-or-later. The surrounding `flutter_libserialport` plugin is MIT,
but that does not change the licenses of its bundled C source or Dart dependency.
The full LGPL and GPL license texts are in `licenses/`.

You may modify these components and reverse engineer Portly for debugging such
modifications. Portly imposes no additional restriction on those activities.
Use the Portly source archive matching the distributed binary, including
`pubspec.lock`, `assets/`, `macos/`, `windows/`, and `tool/` build scripts.
No Portly signing key, online activation, or private dependency is needed for
building and running a locally modified copy.

## Source and build environment

The sources included here are:

1. `sources/libserialport-0.1.1-upstream.tar.gz`: complete upstream native source
   for the macOS Pod. Upstream tag `libserialport-0.1.1`, commit
   `348a6d353af8ac142f68fbf9fe0f4d070448d945`.
2. `sources/flutter_libserialport-0.6.0-resolved-source.tar.gz`: complete resolved
   plugin package, including `third_party/libserialport`, `windows/libserialport`,
   Windows CMake files, and the original license/copyright notices. Its native
   source snapshot is the Windows source of record; it is not assumed to match
   the older macOS Pod source.
3. `sources/libserialport-0.3.0+1-resolved-source.tar.gz`: complete resolved LGPL
   Dart bindings/package, including the preferred Dart source for modifications.

The recorded application build uses Flutter 3.47.7 / Dart 3.13.5. A macOS build
requires Xcode command-line tools and CocoaPods; the Pod's preparation step uses
Autoconf/Automake/libtool (`brew install autoconf automake libtool`). The native
macOS build recipe is `native/macos/libserialport-0.1.1.podspec.json`.
A Windows build requires the Flutter desktop toolchain, Visual Studio's C++
desktop workload, Windows SDK, and the C++ tools for the desired x64 or ARM64
target. Rebuilding is platform-specific; the source and recipe are supplied,
without claiming bit-for-bit reproducibility across toolchain versions.

Verify material integrity from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

On Windows, use `Get-FileHash -Algorithm SHA256` and compare the recorded digest.
The SHA256SUMS names are relative to this directory.

## Modify the LGPL Dart package and rebuild the whole application

Extract both resolved package archives into a writable `vendor/` directory in
the matching Portly source tree. Edit the LGPL Dart source as needed. Create a
local `pubspec_overrides.yaml` (paths below are relative to the Portly root):

```yaml
dependency_overrides:
  libserialport:
    path: vendor/libserialport-0.3.0+1
  flutter_libserialport:
    path: vendor/flutter_libserialport-0.6.0
```

Then resolve and rebuild with the matching Flutter SDK:

```sh
flutter pub get
flutter build macos --release
```

Or, on a native Windows host with the Flutter SDK of the desired architecture:

```powershell
flutter pub get
flutter build windows --release
```

Flutter 3.47.7 chooses Windows x64 or ARM64 from the running SDK's host platform;
use the corresponding native SDK/host rather than a `--target-platform` flag.
The macOS command may generate a universal bundle containing both x86_64 and
arm64; the arm64 slice runs on Apple Silicon. Follow the repository's release
packaging script when producing an arm64-only distribution.

Use the entire resulting Release bundle, not only the executable. This rebuilds
the AOT Dart portion as well as the plugins and permits changes to the LGPL Dart
bindings. Changing only the C dynamic library does not replace the Dart code.

## Modify or replace native libserialport on Windows

Edit `vendor/flutter_libserialport-0.6.0/third_party/libserialport/` and rebuild
the app as above. The included `windows/libserialport/CMakeLists.txt` compiles
`serialport.c`, `timing.c`, and `windows.c` as a shared `serialport` library using
the included `windows/libserialport/config.h` and `LIBSERIALPORT_MSBUILD` define;
it links Windows `cfgmgr32` and `SetupAPI` system libraries.

You can also configure just that included CMake subdirectory with a matching
Visual Studio generator and `-A x64` or `-A ARM64`, then build the `serialport`
target in Release mode. Replace the distributed `serialport.dll` with the
interface-compatible modified DLL of the same architecture while Portly is
closed. The original `flutter_libserialport_plugin.dll` remains separate. Keep
the exported `sp_*` ABI expected by the supplied Dart bindings.

## Modify or replace native libserialport on macOS

For an application rebuild, extract the upstream source, modify it, and use a
local CocoaPods development Pod rather than fetching a different upstream
version. Keep the enclosed Podspec's build flags, framework module name,
generated-header preparation, and source selection. In `macos/Podfile`, add an
explicit local Pod declaration inside the existing Runner target:

```ruby
pod 'libserialport', :path => '../vendor/libserialport-native'
```

Place the supplied `native/macos/libserialport-0.1.1.podspec.json` in that source
directory as `libserialport.podspec.json`. Run `pod install` from `macos/` and
rebuild the application. The Pod's existing `autogen.sh` / `configure` step
regenerates the configuration/header; the originals used for this release are
provided in `native/macos/config.h` and `native/macos/libserialport.h` for
comparison. The supplied upstream C sources match the compiled inputs recorded
in `native/macos/source-verification.json`.

For direct dynamic replacement, use the rebuilt ABI-compatible framework of
the same architecture and preserve its `libserialport.framework` name and
`@rpath` install name. Replace the copy at
`Portly.app/Contents/Frameworks/libserialport.framework` while Portly is closed.
`otool -L` and `file` can verify the dependencies and architecture. Replacing a
framework invalidates the app's existing signature; sign your modified copy
locally. From the matching Portly source root, for example:

```sh
codesign --force --sign - Portly.app/Contents/Frameworks/libserialport.framework
codesign --force --sign - --entitlements macos/Runner/Release.entitlements Portly.app
codesign --verify --deep --strict Portly.app
```

An Apple Developer ID is not needed for this local ad-hoc signing path. Normal
OS security prompts may apply to a newly built or modified application.

## Redistribution of a modified build

Keep the applicable third-party license/copyright notices, mark library changes
as required by their licenses, provide the corresponding modified library
source and application material needed to recombine/rebuild it, and regenerate
the package/engine notices for the actual build. Portly's Apache-2.0 grant does
not replace the LGPL obligations for the components described above.
