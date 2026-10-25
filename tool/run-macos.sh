#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
source ./tool/macos-env.sh
if ! xcodebuild -version >/dev/null 2>&1; then
  print -u2 '未找到 Xcode。请安装到 /Applications/Xcode.app。'
  exit 1
fi
exec ./tool/flutter.sh run -d macos "$@"
