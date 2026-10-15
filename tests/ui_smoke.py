#!/usr/bin/env python3
"""ネイティブのボタン処理・表示・公開中の通常終了を検証する。"""
import json
from pathlib import Path
import subprocess
import time
from integration import APP, ROOT, read, wait, alive, curl


def main():
    base = ROOT / 'test-results' / ('ui-' + time.strftime('%Y%m%d-%H%M%S'))
    result = {}
    for name, flag in [('local', '--ui-smoke'), ('public-quit', '--ui-public-smoke')]:
        directory = base / name
        directory.mkdir(parents=True)
        with (directory / 'app.log').open('w') as log:
            process = subprocess.Popen([str(APP), flag, '--run-directory', str(directory)], stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=260 if name == 'public-quit' else 30)
                assert process.returncode == 0, process.returncode
                state = read(directory / 'state.json')
                assert state['active'] is False
                assert state['shutdownComplete'] is True
                if name == 'local':
                    assert (directory / 'ui-local.png').is_file()
                    assert (directory / 'ui-stopped.png').is_file()
                    assert state['vmPresent'] is False
                else:
                    assert (directory / 'ui-public.png').is_file()
                    guard = read(directory / 'watchdog.json')
                    wait(lambda: not alive(guard['watchdogPID']) and not alive(guard['tunnelPID']), 9)
                    status, body, _ = curl(state['url'] + '/honeyobs-test-after-ui-quit')
                    assert body != b'Not found\n'
                    result['publicStatusAfterQuit'] = status
                result[name] = 'PASS'
                print('ネイティブUI ' + name + ': PASS', flush=True)
            finally:
                if process.poll() is None:
                    process.kill(); process.wait()
                guard = read(directory / 'watchdog.json')
                if guard:
                    wait(lambda: not alive(guard['watchdogPID']) and not alive(guard['tunnelPID']), 9)
    (base / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print('画面と記録:', base)


if __name__ == '__main__':
    main()
