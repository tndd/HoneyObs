#!/bin/bash
# 開発用インストール。完成したアプリの実行にはこのスクリプトも開発ツールも不要。
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source_app="$PWD/build/HoneyObs.app"
rollback=0
if [[ "${1:-}" == --rollback ]]; then rollback=1; shift; fi
if (( $# > 1 )); then echo '使用法: install.sh [--rollback] [インストール先ディレクトリ]' >&2; exit 2; fi
install_root="${1:-$HOME/Applications}"
mkdir -p "$install_root"
install_root="$(cd "$install_root" && pwd -P)"
target_app="$install_root/HoneyObs.app"
backup_app="$install_root/.HoneyObs-previous.app"
if (( rollback )); then source_app="$backup_app"; fi
if [[ -L "$target_app" || -L "$backup_app" ]]; then echo 'アプリのシンボリックリンクは置換できません。' >&2; exit 1; fi
test -f "$source_app/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict "$source_app"
# 実行ファイルを開いているプロセスを確認する。パスを正規表現へ展開しない。
if [[ -e "$target_app/Contents/MacOS/HoneyObs" ]] && /usr/sbin/lsof -t "$target_app/Contents/MacOS/HoneyObs" >/dev/null 2>&1; then
  echo 'HoneyObsを終了してからインストールしてください。' >&2; exit 1
fi
stage="$(mktemp -d "$install_root/.HoneyObs-install.XXXXXX")"
old_app=""; prior_backup=""; candidate_installed=0; committed=0
register_app() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
}
cleanup() {
  local status=$? recovery_failed=0
  trap - EXIT INT TERM
  if (( ! committed )); then
    if (( candidate_installed )) && [[ -e "$target_app" ]]; then
      mv "$target_app" "$stage/rejected.app" || recovery_failed=1
    fi
    if [[ -n "$old_app" && -e "$old_app" ]]; then
      if (( ! recovery_failed )); then mv "$old_app" "$target_app" || recovery_failed=1; fi
      if (( ! recovery_failed )); then register_app || true; fi
    fi
    if [[ -n "$prior_backup" && -e "$prior_backup" ]]; then
      mv "$prior_backup" "$backup_app" || recovery_failed=1
    fi
  fi
  if (( recovery_failed )); then
    echo "自動復旧を完了できませんでした。旧版を削除せず保持しました: $stage" >&2
    exit 1
  fi
  rm -rf "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$source_app" "$stage/HoneyObs.app"
codesign --verify --deep --strict "$stage/HoneyObs.app"
if [[ -e "$target_app" ]]; then
  mv "$target_app" "$stage/previous.app"; old_app="$stage/previous.app"
fi
mv "$stage/HoneyObs.app" "$target_app"; candidate_installed=1
codesign --verify --deep --strict "$target_app"
register_app
if [[ -n "$old_app" ]]; then
  if [[ -e "$backup_app" ]]; then
    mv "$backup_app" "$stage/prior-backup.app"; prior_backup="$stage/prior-backup.app"
  fi
  mv "$old_app" "$backup_app"; old_app="$backup_app"
fi
committed=1
echo "インストール完了: $target_app"
if [[ -e "$backup_app" ]]; then echo "直前の版: $backup_app（復元: bash scripts/install.sh --rollback \"$install_root\"）"; fi
