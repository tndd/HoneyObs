#!/bin/bash
# 専用の実Macで明示実行する。ユーザーの導入済みアプリ・公開・スリープを操作しない。
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'このゲートにはApple Siliconの実Macが必要です。' >&2; exit 1
fi
lock="${TMPDIR:-/tmp}/HoneyObs-real-mac-qa.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "別の実Mac検証が進行中か、以前のロックが残っています: $lock" >&2; exit 1
fi
trap 'rm -f "$lock/pid"; rmdir "$lock"' EXIT
printf '%s\n' "$$" > "$lock/pid"
bash scripts/build.sh
python3 scripts/check_bundle.py
python3 tests/integration.py --local
bash tests/lifecycle.sh
python3 tests/self_pentest.py
