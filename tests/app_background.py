#!/usr/bin/env python3
"""自アプリの最小化・非表示で、localhost転送のfreshnessと安全停止を確認する。

JSによる追加の状態取得、他アプリの操作、画面ロック、スリープ、公開は行わない。
native background-state.jsonと実HTTP、OSのVZ helperを独立の観測に使う。
"""
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP = Path(os.environ.get('HONEYOBS_APP', ROOT / 'build/HoneyObs.app')).resolve()
EXE = APP / 'Contents/MacOS/HoneyObs'
OUT = ROOT / 'test-results' / ('app-background-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
REPORT = {'app': str(APP), 'publicTunnel': False, 'extraJavaScriptEvaluation': False, 'cases': {}}


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def wait(predicate, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if value := predicate():
            return value
        time.sleep(.05)
    raise AssertionError('背景検証の待機期限を超えました')


def command(run, action):
    path = run / 'ui-command'
    wait(lambda: not path.exists(), 5)
    temporary = run / 'ui-command.tmp'
    temporary.write_text(action)
    temporary.replace(path)
    wait(lambda: not path.exists(), 5)


def process(pid):
    return subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='], capture_output=True,
                          text=True, timeout=5).stdout.strip()


def helpers(pid):
    domain = subprocess.run(['/bin/launchctl', 'print', 'pid/' + str(pid)], capture_output=True, text=True, timeout=5)
    assert domain.returncode == 0 and f'creator = HoneyObs[{pid}]' in domain.stdout, domain.stdout[-1000:]
    entries = re.findall(r'^\s+(\d+)\s+\S+\s+(com\.apple\.Virtualization\.VirtualMachine\.[A-Fa-f0-9-]+)\s*$', domain.stdout, re.M)
    assert entries, '実VZ helperのOS所有情報がありません'
    return [{'pid': int(pid), 'service': service, 'identity': process(int(pid))} for pid, service in entries]


def helpers_gone(entries):
    return all(process(entry['pid']) != entry['identity'] for entry in entries)


def request(port, host):
    try:
        with socket.create_connection(('127.0.0.1', port), .5) as stream:
            stream.settimeout(.8)
            stream.sendall(f'GET /background-qa HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
            response = stream.recv(256)
            if not response:
                return 'closed'
            assert b' 404 ' in response.split(b'\r\n', 1)[0], response
            return 'accepted'
    except (ConnectionRefusedError, ConnectionResetError, BrokenPipeError):
        return 'closed'
    except socket.timeout:
        return 'waiting'


def fresh(run):
    path = run / 'background-state.json'
    value = read(path)
    if not value:
        return None
    # 同一native snapshotの時計を使う。プロセス間でclock epochを混ぜない。
    now = value['safetyNow']
    valid = (value['permitValid'] and value['permitDeadline'] > now
             and 0 <= now - value['guestConfirmedAt'] < 3.1
             and 0 <= now - value['uiConfirmedAt'] < 3.1
             and time.time() - path.stat().st_mtime < 1.6)
    return value if valid else None


def main():
    assert APP != (Path.home() / 'Applications/HoneyObs.app').resolve(), '検証は作業tree内のアプリを指定してください'
    assert EXE.is_file()
    OUT.mkdir(mode=0o700, parents=True)
    for action, restore, property_name in [('minimize', 'restore', 'windowMiniaturized'), ('hide', 'show', 'appHidden')]:
        run = OUT / action
        run.mkdir(mode=0o700)
        witness, held, owner = [], None, {}
        with (run / 'launcher.log').open('w') as log:
            wrapper = subprocess.Popen([str(EXE), '--test-mode', '--run-directory', str(run)], stdout=log, stderr=log)
            try:
                native = wait(lambda: read(run / 'background-state.json'), 20)
                pid = native['pid']
                assert str(EXE) + ' --session-client ' in process(pid), process(pid)
                owner = read(run / 'owner.json')
                command(run, 'local-origin')
                state = wait(lambda: s if (s := read(run / 'state.json')).get('originPort') else None, 45)
                port, host = state['originPort'], wait(lambda: read(run / 'test-origin.json').get('host'))
                wait(lambda: fresh(run))
                assert not state['url'] and not (run / 'tunnel.log').exists()
                witness = helpers(pid)
                held = socket.create_connection(('127.0.0.1', port), 1)
                held.sendall(f'POST /login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx'.encode())
                assert not select.select([held], [], [], .1)[0], '背景化前に低速接続が閉じています'
                command(run, action)
                wait(lambda: read(run / 'background-state.json').get(property_name) is True)
                samples, cutoff, expired_at, held_closed_at = [], None, None, None
                background_start = time.monotonic()
                end = time.monotonic() + 8
                while time.monotonic() < end:
                    before = read(run / 'state.json')
                    native = read(run / 'background-state.json')
                    result = request(port, host)
                    current = read(run / 'state.json')
                    if native and (native['safetyNow'] >= native['permitDeadline'] or not native['permitValid']):
                        expired_at = expired_at or time.monotonic()
                    if expired_at is not None:
                        assert result != 'accepted', 'nativeで失効を確認した後もHTTPを受理しました'
                        assert time.monotonic() - expired_at < 3.6 or result == 'closed', '失効後の入口遮断期限を超えました'
                    if held_closed_at is None and select.select([held], [], [], 0)[0]:
                        try:
                            if held.recv(1024) == b'':
                                held_closed_at = round(time.monotonic() - background_start, 3)
                        except ConnectionResetError:
                            held_closed_at = round(time.monotonic() - background_start, 3)
                    if result == 'accepted':
                        assert before.get('active'), '停止要求後もHTTPを受理しました'
                        # 受信後に停止へ遷移した要求を、停止後の新規受理へ読み替えない。
                        snapshot = wait(lambda: fresh(run), 1.6) if current.get('active') else native
                        assert snapshot['permitValid'] and snapshot['permitDeadline'] > snapshot['safetyNow']
                        samples.append({'response': result, 'uiAge': round(snapshot['safetyNow'] - snapshot['uiConfirmedAt'], 3),
                                        'guestAge': round(snapshot['safetyNow'] - snapshot['guestConfirmedAt'], 3)})
                    elif not current.get('active', True):
                        cutoff = wait(lambda: s if (s := read(run / 'state.json')).get('shutdownComplete') else None)
                        assert request(port, host) == 'closed'
                        wait(lambda: helpers_gone(witness), 8)
                        break
                    time.sleep(.15)
                command(run, restore)
                wait(lambda: read(run / 'background-state.json').get(property_name) is False)
                background_cutoff = cutoff is not None
                if cutoff:
                    time.sleep(1)
                    assert not read(run / 'state.json')['active'] and request(port, host) == 'closed', '表示復帰で自動再開しました'
                else:
                    assert len(samples) >= 5 and request(port, host) == 'accepted', samples
                    (run / 'command').write_text('stop')
                    cutoff = wait(lambda: s if (s := read(run / 'state.json')).get('shutdownComplete') else None)
                    assert not cutoff['vmPresent'] and request(port, host) == 'closed'
                    wait(lambda: helpers_gone(witness), 8)
                if held_closed_at is None:
                    def held_closed():
                        if not select.select([held], [], [], 0)[0]:
                            return False
                        try:
                            return held.recv(4096) == b''
                        except ConnectionResetError:
                            return True
                    wait(held_closed, 2)
                    held_closed_at = round(time.monotonic() - background_start, 3)
                REPORT['cases'][action] = {'nativeState': read(run / 'background-state.json'), 'acceptedSamples': samples,
                                          'stoppedState': cutoff, 'xpcOwnershipWitness': witness, 'xpcGoneBeforeCleanup': True,
                                          'heldClosedWithin': held_closed_at,
                                          'backgroundOutcome': 'safety-cutoff' if background_cutoff else 'continued-with-freshness'}
                wrapper.terminate()
                wrapper.wait(timeout=15)
                assert wrapper.returncode == 0, wrapper.returncode
                wait(lambda: all(not process(owner[key]) for key in ['ownerPID', 'clientPID']))
                print(action + ': PASS', flush=True)
            except BaseException as error:
                REPORT['cases'][action] = {'failed': repr(error), 'stateBeforeCleanup': read(run / 'state.json'),
                                          'nativeBeforeCleanup': read(run / 'background-state.json'), 'witness': witness}
                (OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
                raise
            finally:
                if held:
                    held.close()
                if wrapper.poll() is None:
                    wrapper.terminate()
                    try:
                        wrapper.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        wrapper.kill(); wrapper.wait()
    (OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
    print('自アプリの背景化・freshness・停止後VZ回収: PASS', OUT)


if __name__ == '__main__':
    main()
