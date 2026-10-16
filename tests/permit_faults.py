#!/usr/bin/env python3
"""外部公開せず、実GUI・製品Relay・実VMとOS監視の期限を検証する。"""
import json
import os
import pathlib
import select
import socket
import subprocess
import threading
import time
from integration import xpc_helpers, bootout_owned, alive

root = pathlib.Path(__file__).resolve().parent.parent
out = root / 'test-results' / ('permit-faults-' + time.strftime('%Y%m%d-%H%M%S'))
out.mkdir(parents=True, mode=0o700)
app = pathlib.Path(os.environ.get('HONEYOBS_APP', root / 'build/HoneyObs.app')).resolve()
exe = app / 'Contents/MacOS/HoneyObs'


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def wait(predicate, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('確認の待機期限を超えました')


def command(run, text):
    wait(lambda: not (run / 'ui-command').exists(), 5)
    (run / 'ui-command').write_text(text)


def closed(port):
    try:
        with socket.create_connection(('127.0.0.1', port), .3):
            return False
    except OSError:
        return True


summary = {'externalTunnel': False, 'actualVM': True, 'cases': {}}
for fault in ['freeze-main', 'freeze-ui']:
    run = out / fault
    run.mkdir(mode=0o700)
    connection = None
    with (run / 'app.log').open('w') as log:
        process = subprocess.Popen([str(exe), '--test-mode', '--ui-exercise-smoke', '--run-directory', str(run)], stdout=log, stderr=log, cwd='/tmp')
        try:
            state = wait(lambda: s if (s := read(run / 'state.json')).get('originPort') else None, 40)
            owner = wait(lambda: read(run / 'owner.json'))
            helpers = xpc_helpers(state['pid'])
            port = state['originPort']; host = read(run / 'test-origin.json')['host']
            connection = socket.create_connection(('127.0.0.1', port), 1)
            connection.sendall(f'POST /login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx'.encode())
            time.sleep(.1)
            assert not select.select([connection], [], [], 0)[0], '故障注入前に既存接続が終了しています'
            command(run, fault); wait(lambda: not (run / 'ui-command').exists(), 5)
            started = time.monotonic(); late = {}
            def probe_after_expiry():
                time.sleep(max(0, 3.25 - (time.monotonic() - started)))
                late['attemptedAt'] = round(time.monotonic() - started, 3)
                try:
                    with socket.create_connection(('127.0.0.1', port), .5) as probe:
                        probe.settimeout(2)
                        probe.sendall(f'GET /qa-after-permit-expiry HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
                        try:
                            data = probe.recv(100)
                        except (ConnectionResetError, TimeoutError):
                            data = b''
                        late['denied'] = data == b''
                except OSError:
                    late['denied'] = True
            thread = threading.Thread(target=probe_after_expiry); thread.start()
            connection.settimeout(6)
            try:
                data = connection.recv(100)
            except ConnectionResetError:
                data = b''
            elapsed = time.monotonic() - started
            assert data == b'' and elapsed < 6, (fault, elapsed, data)
            thread.join(timeout=3)
            assert not thread.is_alive() and late.get('denied') and late['attemptedAt'] >= 3.2, late
            if fault == 'freeze-main':
                wait(lambda: not alive(owner['clientPID']) and not alive(owner['ownerPID']) and all(not alive(pid) for pid in helpers), 8)
                for field in ['clientService', 'ownerService']:
                    assert subprocess.run(['/bin/launchctl', 'print', owner[field]], capture_output=True).returncode != 0
                final = read(run / 'state.json')
                # A dead/frozen UI's stale JSON is never used as a stop witness.
                assert closed(port)
            else:
                final = wait(lambda: s if (s := read(run / 'state.json')).get('shutdownComplete') else None, 12)
                assert not final['vmPresent'] and not final['active'] and closed(port), final
                wait(lambda: all(not alive(pid) for pid in helpers))
                assert alive(owner['clientPID']), 'WebKit故障後も操作画面の停止結果を保持する必要があります'
                time.sleep(.5)
                assert read(run / 'state.json')['shutdownComplete'] and closed(port), '失効したセッションが復活しました'
            summary['cases'][fault] = {'existingSocketClosedWithin': round(elapsed, 3), 'newAfterExpiry': late,
                                      'actualVZHelpersGoneBeforeCleanup': True, 'state': final}
        finally:
            if connection:
                connection.close()
            if process.poll() is None:
                if alive(read(run / 'owner.json').get('clientPID')):
                    command(run, 'quit')
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    bootout_owned(run); process.terminate(); process.wait(timeout=5)
            bootout_owned(run)
(out / 'report.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print('実GUI/VMの期限失効・既存接続終了・失効後の新規要求拒否: PASS', out)
