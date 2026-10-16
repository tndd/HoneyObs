#!/bin/bash
# 開発用インストール。完成したアプリの実行にはこのスクリプトも開発ツールも不要。
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/HoneyObs.app"
install_root="${1:-$HOME/Applications}"
target_app="$install_root/HoneyObs.app"
test -f "$source_app/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict "$source_app"
mkdir -p "$install_root"
# 起動中のバンドルを置き換えない。既存版は退避して復旧可能にする。
if /usr/bin/pgrep -f "^$target_app/Contents/MacOS/HoneyObs( |$)" >/dev/null; then
  echo 'HoneyObsを終了してからインストールしてください。' >&2; exit 1
fi
stage="$(mktemp -d "$install_root/.HoneyObs-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$source_app" "$stage/HoneyObs.app"
codesign --verify --deep --strict "$stage/HoneyObs.app"
if test -e "$target_app"; then mv "$target_app" "$stage/旧HoneyObs.app"; fi
if ! mv "$stage/HoneyObs.app" "$target_app"; then
  if test -e "$stage/旧HoneyObs.app"; then mv "$stage/旧HoneyObs.app" "$target_app"; fi
  exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
echo "インストール完了: $target_app"
