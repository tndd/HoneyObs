#!/usr/bin/env python3
"""実アプリのWebKitボタン→Engine→公開要求→一覧・地図→停止・再開を検証。"""
import json
import subprocess
import time
from integration import APP, ROOT, read, wait, alive, curl


def main():
    directory = ROOT / 'test-results' / ('dashboard-' + time.strftime('%Y%m%d-%H%M%S'))
    directory.mkdir(mode=0o700, parents=True)
    report = {}
    with (directory / 'app.log').open('w') as log:
        process = subprocess.Popen([str(APP), '--test-mode', '--ui-dashboard-smoke', '--run-directory', str(directory)], stdout=log, stderr=subprocess.STDOUT)
        def ui():
            return read(directory / 'ui-state.json')
        def state():
            value = read(directory / 'state.json')
            if value.get('phase') in ('エラー', '停止失敗'):
                raise AssertionError(value['detail'])
            return value
        def command(action):
            wait(lambda: not (directory / 'ui-command').exists(), 10)
            (directory / 'ui-command').write_text(action)
        def capture(name):
            target = directory / 'ui-capture.png'
            target.unlink(missing_ok=True)
            command('capture')
            wait(lambda: target.exists(), 15)
            target.replace(directory / name)
        try:
            wait(lambda: ui().get('canStart'), 30)
            assert ui()['rows'] == 0
            capture('empty.png')
            command('public')
            public = wait(lambda: s if (s := state()).get('phase') == '公開中' else None, 240)
            status, _, _ = curl(public['url'] + '/login', '-X', 'POST')
            assert status == 401
            shown = wait(lambda: s if (s := ui()).get('request') == 'POST /login' else None, 20)
            raw = read(directory / 'events.json')['events'][-1]
            assert shown['ip'] == raw['ip'] and shown['country'] != '位置不明', '実IPの表示または国照会を確認できません'
            assert shown['routes'] == 1 and not shown['overflow']
            command('last')
            wait(lambda: ui().get('request') == 'GET /honeyobs-test-ready', 10)
            command('first')
            wait(lambda: ui().get('request') == 'POST /login', 10)
            capture('public-received.png')
            command('resize')
            wait(lambda: ui().get('width') == 860, 10)
            assert not ui()['overflow']
            capture('compact.png')
            command('stop')
            wait(lambda: ui().get('phase') == '停止完了' and ui().get('canStart'), 20)
            assert ui()['rows'] >= 2 and ui()['request'] == 'POST /login'
            assert ui()['packets'] == 0 and ui()['url'] == '公開URLなし'
            guard = read(directory / 'watchdog.json')
            wait(lambda: not alive(guard['watchdogPID']) and not alive(guard['tunnelPID']), 10)
            status, body, _ = curl(public['url'] + '/honeyobs-test-after-dashboard-stop')
            assert body != b'Not found\n'
            capture('stopped.png')
            command('local')
            wait(lambda: ui().get('phase') == 'ローカル準備完了', 40)
            assert ui()['rows'] == 0 and ui()['count'] == '0'
            command('stop')
            wait(lambda: ui().get('canStart'), 15)
            command('quit')
            process.wait(timeout=10)
            assert process.returncode == 0
            report = {'nativeWebKit': 'PASS', 'publicRequestToMap': 'PASS', 'selectionDisplayed': 'PASS',
                      'minimumWindow': 'PASS', 'stopKeepsHistory': 'PASS', 'restartClearsSession': 'PASS',
                      'tunnelClosed': 'PASS', 'actualSleep': 'ユーザー指定により未実施'}
            print('実Mac GUI・公開受信→地図・停止・再開: PASS', flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=8)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            guard = read(directory / 'watchdog.json')
            if guard:
                wait(lambda: not alive(guard['watchdogPID']) and not alive(guard['tunnelPID']), 10)
            (directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
            print('画面と記録:', directory)


if __name__ == '__main__':
    main()
