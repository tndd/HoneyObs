#!/usr/bin/env python3
"""実アプリの起動中終了と監視役異常終了時の誤った完了表示を検査する。"""
import json
import os
import signal
import subprocess
from integration import APP, OUT, Session, read, wait, alive


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    directory = OUT / 'terminate-starting'
    directory.mkdir()
    with (directory / 'app.log').open('w') as log:
        process = subprocess.Popen([str(APP), '--headless', '--run-directory', str(directory)], stdout=log, stderr=log)
        try:
            wait(lambda: read(directory / 'state.json').get('active') is True)
            process.terminate()
            process.wait(timeout=12)
            state = read(directory / 'state.json')
            assert process.returncode == 0 and state['shutdownComplete'] and not state['vmPresent'], state
            report['applicationTerminationWaitsForVM'] = 'PASS'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    session = Session('watchdog-loss', public=True)
    try:
        guard = wait(lambda: read(session.directory / 'watchdog.json'))
        os.kill(guard['watchdogPID'], signal.SIGKILL)
        state = wait(lambda: s if (s := read(session.directory / 'state.json')).get('phase') == '停止失敗' else None, 12)
        assert state['active'] is False and state['vmPresent'] is False, state
        assert state['shutdownComplete'] is False and state['canStart'] is False, state
        # 回収未確認を報告することがこの段階の契約。監視役故障からの全回収を証明したとはしない。
        report['watchdogCrashIsNotReportedAsStopped'] = 'PASS'
        report['tunnelAliveBeforeTestCleanup'] = alive(guard['tunnelPID'])
        report['observedBeforeCleanup'] = True
    finally:
        session.cleanup()
        guard = read(session.directory / 'watchdog.json')
        wait(lambda: not alive(guard.get('watchdogPID')) and not alive(guard.get('tunnelPID')), 5)
    (OUT / 'stop-edges-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('実アプリの終了待機・監視役異常終了の未確認表示: PASS')
    print('検証記録:', OUT)


if __name__ == '__main__':
    main()
