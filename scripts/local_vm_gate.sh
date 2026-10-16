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
cleanup() {
  local qa_exit_status=$?
  trap - EXIT
  if ! python3 tests/qa_registry.py "$PWD/build/HoneyObs.app"; then
    if [[ "$qa_exit_status" == 0 ]]; then qa_exit_status=1; fi
  fi
  rm -f "$lock/pid"
  rmdir "$lock"
  exit "$qa_exit_status"
}
trap cleanup EXIT
printf '%s\n' "$$" > "$lock/pid"
bash scripts/build.sh
python3 scripts/check_bundle.py
python3 tests/session_control.py
python3 tests/session_jobs.py
python3 tests/menu_tracking.py
python3 tests/integration.py --local
bash tests/lifecycle.sh
python3 tests/egress_privileges.py
bash tests/egress.sh --vm
bash tests/egress_engine.sh
bash tests/relay_closure.sh "$PWD/build/HoneyObs.app/Contents/Resources"
python3 tests/final_observation.py
bash scripts/ownership_gate.sh
python3 tests/self_pentest.py --close-after
python3 tests/app_background.py
python3 tests/menu_integration.py
python3 tests/permit_faults.py
