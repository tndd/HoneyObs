#!/usr/bin/env python3
"""起動中の終了と、OS監視job故障による実VM回収を検査する（外部公開なし）。"""
import json
import os
import signal
import subprocess
from integration import APP, OUT, Session, read, wait, alive, bootout_owned
from qa_registry import register_app, require_cleanup


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    directory = OUT / 'terminate-starting'
    directory.mkdir(mode=0o700)
    with (directory / 'app.log').open('w') as log:
        register_app(APP.parents[2])
        process = subprocess.Popen([str(APP), '--test-mode', '--headless', '--run-directory', str(directory)], stdout=log, stderr=log)
        try:
            wait(lambda: read(directory / 'state.json').get('active') is True)
            process.terminate()
            process.wait(timeout=12)
            state = read(directory / 'state.json')
            assert process.returncode == 0 and state['shutdownComplete'] and not state['vmPresent'], state
            report['applicationTerminationWaitsForVM'] = 'PASS'
        finally:
            bootout_owned(directory)
            if process.poll() is None:
                process.kill(); process.wait()

    session = Session('monitor-loss', local_origin=True)
    try:
        state = session.ready()
        owner = wait(lambda: read(session.directory / 'owner.json'))
        monitor = owner['ownerPID']
        current = subprocess.check_output(['ps', '-p', str(monitor), '-o', 'command='], text=True).strip()
        app = APP.parent.parent
        assert str(app / 'Helpers/HoneyObsSession') in current and '--monitor-job' in current, current
        os.kill(monitor, signal.SIGKILL)
        wait(lambda: not alive(owner['clientPID']) and all(not alive(pid) for pid in session.vz_helpers), 8)
        for field in ['ownerService', 'clientService']:
            wait(lambda: subprocess.run(['/bin/launchctl', 'print', owner[field]], capture_output=True).returncode != 0, 5)
        report['monitorCrashRecoversDirectVZOwner'] = 'PASS'
        report['ownedVZHelpersGoneBeforeTestCleanup'] = True
        report['observedBeforeCleanup'] = True
    finally:
        session.cleanup()
    require_cleanup()
    (OUT / 'stop-edges-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('起動中の終了・OS監視故障からの実VM回収: PASS')
    print('検証記録:', OUT)


if __name__ == '__main__':
    main()
