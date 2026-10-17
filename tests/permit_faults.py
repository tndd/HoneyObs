#!/usr/bin/env python3
"""実GUIのmain 5秒停止とJS無限ループを、私有コピーとlocalhostだけで検査する。"""
import hashlib
import json
import plistlib
import os
import pathlib
import select
import socket
import subprocess
import threading
import time
from integration import xpc_helpers, bootout_owned, alive
from qa_registry import register_app, require_cleanup

root = pathlib.Path(__file__).resolve().parent.parent
out = root / 'test-results' / ('permit-faults-' + time.strftime('%Y%m%d-%H%M%S'))
out.mkdir(parents=True, mode=0o700)
source_app = pathlib.Path(os.environ.get('HONEYOBS_APP', root / 'build/HoneyObs.app')).resolve()
app = out / 'HoneyObs.app'
subprocess.run(['ditto', str(source_app), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
register_app(app)
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
    temporary = run / 'ui-command.tmp'
    temporary.write_text(text); temporary.replace(run / 'ui-command')


def closed(port):
    try:
        with socket.create_connection(('127.0.0.1', port), .3):
            return False
    except OSError:
        return True


summary = {'externalTunnel': False, 'actualVM': True, 'sourceApp': str(source_app), 'privateApp': str(app),
           'appSHA256': hashlib.sha256(exe.read_bytes()).hexdigest(),
           'bundleVersion': plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'],
           'signalResumeApplicable': False, 'signalResumeReason': 'Thread.sleepとJS停止でありSIGSTOPは使わない', 'cases': {}}
for fault in ['freeze-main', 'freeze-ui']:
    run = out / fault
    run.mkdir(mode=0o700)
    connection = None; owner = {}; helpers = []; thread = None; late = {}
    with (run / 'app.log').open('w') as log:
        process = subprocess.Popen([str(exe), '--test-mode', '--ui-dashboard-smoke', '--run-directory', str(run)], stdout=log, stderr=log, cwd='/tmp')
        try:
            owner = wait(lambda: read(run / 'owner.json'))
            wait(lambda: read(run / 'ui-ready.json'))
            command(run, 'local-origin')
            state = wait(lambda: s if (s := read(run / 'state.json')).get('originPort') else None, 40)
            baseline = wait(lambda: s if (s := read(run / 'background-state.json')).get('permitValid')
                            and s['permitDeadline'] > s['safetyNow'] and 0 <= s['safetyNow'] - s['uiConfirmedAt'] < 1.6
                            and 0 <= s['safetyNow'] - s['guestConfirmedAt'] < 1.6 else None)
            helpers = xpc_helpers(state['pid'])
            domain = subprocess.run(['/bin/launchctl', 'print', 'pid/' + str(state['pid'])], capture_output=True, text=True, timeout=5)
            (run / 'xpc-owner.txt').write_text(domain.stdout)
            port = state['originPort']; host = read(run / 'test-origin.json')['host']
            with socket.create_connection(('127.0.0.1', port), 1) as probe:
                probe.settimeout(1)
                probe.sendall(f'GET /qa-before-{os.urandom(16).hex()} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
                assert probe.recv(100).startswith(b'HTTP/1.1 ')
            connection = socket.create_connection(('127.0.0.1', port), 1)
            connection.sendall(f'POST /login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx'.encode())
            time.sleep(.1)
            assert not select.select([connection], [], [], 0)[0], '故障注入前に既存接続が終了しています'
            command(run, fault); wait(lambda: not (run / 'ui-command').exists(), 5)
            started = time.monotonic(); late = {}
            def probe_after_expiry():
                time.sleep(max(0, 3.25 - (time.monotonic() - started)))
                late['existingPayloadAttemptedAt'] = round(time.monotonic() - started, 3)
                try:
                    connection.sendall(b'x' * 99); late['existingPayloadQueuedToKernel'] = True
                except OSError:
                    late['existingPayloadQueuedToKernel'] = False
                nonce = os.urandom(16).hex(); late['nonce'] = nonce
                late['attemptedAt'] = round(time.monotonic() - started, 3)
                try:
                    with socket.create_connection(('127.0.0.1', port), .5) as probe:
                        probe.settimeout(2)
                        probe.sendall(f'GET /qa-after-permit-expiry-{nonce} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
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
            late['existingPayloadResponseDenied'] = True
            if fault == 'freeze-main':
                wait(lambda: not alive(owner['clientPID']) and not alive(owner['ownerPID']) and all(not alive(pid) for pid in helpers), 8)
                for field in ['clientService', 'ownerService']:
                    assert subprocess.run(['/bin/launchctl', 'print', owner[field]], capture_output=True).returncode != 0
                # 5秒停止が戻り得る時刻を越えても、古いJSONを成功根拠にせずOSを再確認する。
                time.sleep(max(0, 5.5 - (time.monotonic() - started)))
                assert not alive(owner['clientPID']) and not alive(owner['ownerPID'])
                assert all(not alive(pid) for pid in helpers) and closed(port)
                process.wait(timeout=5); assert process.returncode == 1
                final = read(run / 'state.json')
            else:
                final = wait(lambda: s if (s := read(run / 'state.json')).get('shutdownComplete') else None, 12)
                assert not final['vmPresent'] and not final['active'] and closed(port), final
                wait(lambda: all(not alive(pid) for pid in helpers))
                assert alive(owner['clientPID']), 'WebKit故障後も操作画面の停止結果を保持する必要があります'
                native = wait(lambda: s if not (s := read(run / 'background-state.json')).get('permitValid', True) else None)
                time.sleep(3.5)
                fresh = read(run / 'background-state.json')
                assert fresh['safetyNow'] > native['safetyNow'] and fresh['uiConfirmedAt'] == native['uiConfirmedAt']
                assert fresh['safetyNow'] - fresh['uiConfirmedAt'] > 3 and not fresh['permitValid']
                assert read(run / 'state.json')['shutdownComplete'] and closed(port), '失効したセッションが復活しました'
                assert all(not alive(pid) for pid in helpers) and alive(owner['ownerPID'])
                command(run, 'quit'); process.wait(timeout=12); assert process.returncode == 0
                assert not alive(owner['clientPID']) and not alive(owner['ownerPID'])
                assert all(subprocess.run(['/bin/launchctl', 'print', owner[field]], capture_output=True, timeout=5).returncode == 113
                           for field in ['clientService', 'ownerService'])
            assert not pathlib.Path(owner['socketDirectory']).exists()
            summary['cases'][fault] = {'existingSocketClosedWithin': round(elapsed, 3), 'newAfterExpiry': late,
                                      'actualVZHelpersGoneBeforeCleanup': True, 'bothJobsGoneBeforeCleanup': True,
                                      'freshBaseline': baseline, 'noResurrectionObservedUntil': round(time.monotonic() - started, 3),
                                      'state': final}
        except BaseException as error:
            summary['cases'][fault] = {'failed': repr(error), 'owner': owner, 'state': read(run / 'state.json'),
                                      'native': read(run / 'background-state.json'), 'newAfterExpiry': late,
                                      'helpersBeforeCleanup': {str(pid): alive(pid) for pid in helpers}}
            (out / 'report.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
            raise
        finally:
            if thread:
                thread.join(timeout=2)
            if connection:
                connection.close()
            if process.poll() is None:
                if alive(owner.get('clientPID')):
                    command(run, 'quit')
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    bootout_owned(run); process.terminate(); process.wait(timeout=5)
            bootout_owned(run)
require_cleanup()
(out / 'report.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
for fault in summary['cases']:
    print(fault + ': PASS', flush=True)
print('実GUI/VMの期限失効・既存接続終了・失効後の新規要求拒否: PASS', out)
