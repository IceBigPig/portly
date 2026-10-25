#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
exec ./tool/flutter.sh run -d chrome --web-port=8766
