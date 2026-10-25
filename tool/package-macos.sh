#!/bin/zsh
# Package a main-entry macOS release without changing global Flutter settings.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./tool/macos-env.sh
exec python3 packaging/macos/package_macos.py "$@"
