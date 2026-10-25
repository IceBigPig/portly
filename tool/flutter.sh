#!/bin/zsh
set -eu
if command -v flutter >/dev/null 2>&1; then
  exec flutter "$@"
elif [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  exec "$HOME/development/flutter/bin/flutter" "$@"
else
  print -u2 '未找到 Flutter，请安装 Flutter stable 并加入 PATH。'
  exit 1
fi
