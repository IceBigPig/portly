#!/bin/zsh
# An isolated app bundle keeps concurrent normal release builds from replacing it.
set -eu
cd "$(dirname "$0")/.."
stress_seconds=${1:-60}
stress_label=${2:-calibration}
stress_directory=${3:-/tmp/portly-pressure-${stress_label}-$(date +%Y%m%d-%H%M%S)}
stress_port=${4:-28710}
if [[ -e "$stress_directory" ]]; then
  print -u2 "Refusing to reuse existing stress directory: $stress_directory"
  exit 1
fi
mkdir -p "$stress_directory"
rg --files lib assets macos tool/stress_main.dart tool/stress_monitor.py tool/stress_report.py tool/stress_run.sh tool/build-macos.sh tool/flutter.sh tool/macos-env.sh pubspec.yaml pubspec.lock > "$stress_directory/source-files.txt"
while IFS= read -r stress_file; do
  shasum -a 256 "$stress_file"
done < "$stress_directory/source-files.txt" > "$stress_directory/sources-before.sha256"
./tool/build-macos.sh -t tool/stress_main.dart \
  --dart-define=STRESS_SECONDS="$stress_seconds" \
  --dart-define=STRESS_DIRECTORY="$stress_directory" \
  --dart-define=STRESS_LABEL="$stress_label" \
  --dart-define=STRESS_PORT="$stress_port" > "$stress_directory/build.txt" 2>&1
while IFS= read -r stress_file; do
  shasum -a 256 "$stress_file"
done < "$stress_directory/source-files.txt" > "$stress_directory/sources.sha256"
if ! cmp -s "$stress_directory/sources-before.sha256" "$stress_directory/sources.sha256"; then
  print -u2 'Production source changed during build; refusing an ambiguous benchmark.'
  exit 1
fi
cp -R build/macos/Build/Products/Release/Portly.app "$stress_directory/PortlyPressure.app"
# A separate test identity prevents Dock/accessibility activation from selecting
# the user's normal app when the two Release processes run together.
stress_plist="$stress_directory/PortlyPressure.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.haike.portly.pressure' "$stress_plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Portly Pressure' "$stress_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Portly Pressure' "$stress_plist"
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$stress_directory/PortlyPressure.app"
shasum -a 256 "$stress_directory/PortlyPressure.app/Contents/Frameworks/App.framework/Versions/A/App" > "$stress_directory/app.sha256"
shasum -a 256 "$stress_plist" > "$stress_directory/app-info.sha256"
codesign --verify --deep --strict "$stress_directory/PortlyPressure.app"
/usr/bin/lipo -archs "$stress_directory/PortlyPressure.app/Contents/MacOS/Portly" > "$stress_directory/architectures.txt"
/usr/bin/sw_vers > "$stress_directory/environment.txt"
/usr/sbin/sysctl -n machdep.cpu.brand_string hw.memsize hw.ncpu >> "$stress_directory/environment.txt"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -version >> "$stress_directory/environment.txt"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version >> "$stress_directory/environment.txt"
./tool/flutter.sh --version >> "$stress_directory/environment.txt"
python3 tool/stress_monitor.py "$stress_directory" "$stress_seconds"
