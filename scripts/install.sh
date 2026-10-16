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
install_lock="$install_root/.HoneyObs-install.lock"
if ! mkdir "$install_lock" 2>/dev/null; then
  echo "別の導入処理が進行中か、以前のロックが残っています: $install_lock" >&2; exit 1
fi
trap 'rmdir "$install_lock"' EXIT
if (( rollback )); then source_app="$backup_app"; fi
if [[ -L "$target_app" || -L "$backup_app" ]]; then echo 'アプリのシンボリックリンクは置換できません。' >&2; exit 1; fi
test -f "$source_app/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict "$source_app"
# 実行ファイルを開いているプロセスを確認する。パスを正規表現へ展開しない。
for protected_app in "$target_app" "$backup_app"; do
  if [[ -e "$protected_app/Contents/MacOS/HoneyObs" ]] && /usr/sbin/lsof -t "$protected_app/Contents/MacOS/HoneyObs" >/dev/null 2>&1; then
    echo 'HoneyObsを終了してからインストールしてください。' >&2; exit 1
  fi
done
stage="$(mktemp -d "$install_root/.HoneyObs-install.XXXXXX")"
old_app=""; prior_backup=""; candidate_installed=0; promoting_backup=0; committed=0
register_app() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
}
cleanup() {
  local status=$? recovery_failed=0
  trap - EXIT INT TERM
  if (( ! committed )); then
    # mv完了直後にシグナルを受けても、実際に旧版がある方から復旧する。
    if (( promoting_backup )) && [[ ! -e "$old_app" && -e "$backup_app" ]]; then old_app="$backup_app"; fi
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
    rmdir "$install_lock" || true
    exit 1
  fi
  rm -rf "$stage"
  rmdir "$install_lock" || exit 1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$source_app" "$stage/HoneyObs.app"
codesign --verify --deep --strict "$stage/HoneyObs.app"
if [[ -e "$target_app" ]]; then
  old_app="$stage/previous.app"; mv "$target_app" "$old_app"
fi
candidate_installed=1; mv "$stage/HoneyObs.app" "$target_app"
codesign --verify --deep --strict "$target_app"
register_app
if [[ -n "$old_app" ]]; then
  if [[ -e "$backup_app" ]]; then
    prior_backup="$stage/prior-backup.app"; mv "$backup_app" "$prior_backup"
  fi
  promoting_backup=1
  mv "$old_app" "$backup_app"; old_app="$backup_app"
fi
committed=1
echo "インストール完了: $target_app"
if [[ -e "$backup_app" ]]; then echo "直前の版: $backup_app（復元: bash scripts/install.sh --rollback \"$install_root\"）"; fi
