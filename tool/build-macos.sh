#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
source ./tool/macos-env.sh
./tool/flutter.sh build macos --release "$@"
# Refresh the outer bundle seal after Flutter's incremental framework replacement.
# Use local ad-hoc signing; no Developer ID identity or keychain access is required.
app_path=build/macos/Build/Products/Release/Portly.app
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
