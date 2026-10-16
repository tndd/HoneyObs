#!/usr/bin/env python3
"""私有コピーの実アプリで停止直前128要求・未完了Relay・最終フェンスを照合する。"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def command(*args):
    return subprocess.run(args, capture_output=True, text=True)


def wait(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.01)
    raise AssertionError('期限内に条件が成立しません')


def process(pid):
    result = command('/bin/ps', '-p', str(pid), '-o', 'stat=,lstart=,command=')
    text = result.stdout.strip()
    return text if text and not text.startswith('Z') else ''


def helpers(pid, directory):
    result = command('/bin/launchctl', 'print', f'pid/{pid}')
    assert result.returncode == 0 and f'creator = HoneyObs[{pid}]' in result.stdout, result.stdout[-1000:]
    (directory / 'xpc-before.txt').write_text(result.stdout)
    entries = re.findall(r'^\s+(\d+)\s+\S+\s+(com\.apple\.Virtualization\.VirtualMachine\.[A-F0-9-]+)\s*$', result.stdout, re.M)
    witnesses = []
    for value, service in entries:
        identity = process(int(value))
        assert '/Virtualization.framework/' in identity, identity
        witnesses.append({'pid': int(value), 'service': service, 'identity': identity})
    assert witnesses, '停止前に実VZ/XPC所有を確認できません'
    return witnesses


def remaining(witnesses):
    return [item['pid'] for item in witnesses if process(item['pid']) == item['identity']]


def console_fds(pid, run, filename):
    result = command('/usr/sbin/lsof', '-n', '-P', '-p', str(pid), '-F', 'ftn')
    assert result.returncode == 0, result.stderr
    (run / filename).write_text(result.stdout)
    targets = {str(run / 'console.log'), str(run / 'tunnel.log')}
    return [line[1:] for line in result.stdout.splitlines() if line.startswith('n') and line[1:] in targets]


def request(port, host, path):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as peer:
        peer.settimeout(3)
        peer.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
        response = bytearray()
        while True:
            chunk = peer.recv(4096)
            if not chunk:
                break
            response += chunk
            assert len(response) <= 65536, '応答上限を超えました'
    header, separator, body = bytes(response).partition(b'\r\n\r\n')
    assert separator and header.split(b'\r\n', 1)[0].split()[1] == b'404' and body == b'Not found\n', (path, bytes(response[:150]))
    return {'path': path, 'status': 404, 'bodySHA256': hashlib.sha256(body).hexdigest()}


def bootout(run):
    owner = read(run / 'owner.json')
    for key in ['clientService', 'ownerService']:
        service = owner.get(key)
        if service:
            assert service.startswith(f'gui/{os.getuid()}/local.honeyobs.'), service
            uuid.UUID(service.rsplit('.', 1)[-1])
            command('/bin/launchctl', 'bootout', service)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'build/HoneyObs.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'test-results' / ('final-observation-' + time.strftime('%Y%m%d-%H%M%S')))
    parser.add_argument('--source-head', default='', help='ビルド元として申告されたHEAD。binary SHAも別に記録する')
    parser.add_argument('--tail-count', type=int, default=128)
    options = parser.parse_args()
    assert 1 <= options.tail_count <= 128
    output = options.output.resolve(); output.mkdir(mode=0o700, parents=True, exist_ok=True)
    app = output / 'private/HoneyObs.app'
    source = options.app.resolve()
    if source != app:
        assert not app.exists(), '既存の試験コピーを上書きしません'
        shutil.copytree(source, app)
    assert command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)).returncode == 0
    binary = app / 'Contents/MacOS/HoneyObs'
    report = {'scope': 'localhost→製品Relay→実VM→最終フェンス→保存。公開トンネルなし',
              'declaredSourceHead': options.source_head, 'privateApp': str(app),
              'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'tailCount': options.tail_count, 'success': False, 'externalPublication': False}
    run = output / 'case'; run.mkdir(mode=0o700)
    launcher = held = None; witnesses = []
    log = (run / 'launcher.log').open('w')
    try:
        launcher = subprocess.Popen([str(binary), '--test-mode', '--headless', '--local-origin', '--run-directory', str(run)], stdout=log, stderr=subprocess.STDOUT)
        def ready():
            state = read(run / 'state.json')
            assert state.get('phase') not in ['エラー', '停止失敗'], state
            return state if state.get('phase') == 'ローカル準備完了' and state.get('originPort') else None
        state = wait(ready, 40); client = state['pid']; port = state['originPort']
        host = wait(lambda: read(run / 'test-origin.json').get('host'))
        witnesses = helpers(client, run); report['helpersBefore'] = witnesses
        before_fds = console_fds(client, run, 'fds-before.txt')
        assert str(run / 'console.log') in before_fds, '実際のconsole FDを停止前に観測できません'
        token = uuid.uuid4().hex
        # seed1件と末尾128件で128件/page境界を超える。未完了接続は最後まで保持する。
        responses = [request(port, host, '/qa-final-seed-' + token)]
        held = socket.create_connection(('127.0.0.1', port), timeout=2)
        incomplete = '/qa-final-held-' + token
        held.sendall(f'GET {incomplete} HTTP/1.1\r\nHost: {host}\r\n'.encode())
        started = time.monotonic()
        for index in range(options.tail_count):
            responses.append(request(port, host, f'/qa-final-{token}-{index:03d}'))
        report['tailSendMilliseconds'] = int((time.monotonic() - started) * 1000)
        held.setblocking(False)
        try:
            held.recv(1, socket.MSG_PEEK)
            raise AssertionError('OFF前に未完了接続が閉じたか応答しました')
        except BlockingIOError:
            report['incompleteRelayOpenBeforeStop'] = True
        pre = read(run / 'events.json'); report['preStopLastID'] = pre.get('lastID', 0)
        assert report['preStopLastID'] < len(responses), '停止前に全件取得済みで最終取得を検証できません'
        stop_started = time.monotonic(); (run / 'command').write_text('stop')
        final_state = wait(lambda: value if (value := read(run / 'state.json')).get('shutdownComplete') else None, 12)
        report['shutdownMilliseconds'] = int((time.monotonic() - stop_started) * 1000)
        report['stateAtShutdown'] = final_state
        report['helpersAtFirstShutdownRead'] = remaining(witnesses)
        assert not report['helpersAtFirstShutdownRead'], '停止完了の最初の観測時にVZ補助プロセスが残っています'
        after_fds = console_fds(client, run, 'fds-after.txt'); report['consoleFDsAfterShutdown'] = after_fds
        assert not after_fds, '停止完了後もVM console/tunnel log FDが残っています'
        assert not final_state['active'] and not final_state['vmPresent'] and not final_state['egressVMPresent'] and final_state['canStart']
        try:
            peer = socket.create_connection(('127.0.0.1', port), timeout=.2)
        except OSError:
            pass
        else:
            peer.close(); raise AssertionError('停止完了後も入口へ接続できます')
        held.settimeout(.5)
        try:
            received = held.recv(4096)
        except (ConnectionResetError, BrokenPipeError):
            received = b''
        assert received == b'', '許可失効後に未完了Relayから応答が転送されました'
        wait(lambda: not remaining(witnesses), 9)
        report['helperGoneMilliseconds'] = int((time.monotonic() - stop_started) * 1000)
        archive = read(run / 'events.json'); receipt = read(run / 'final-observation.json'); observation = read(run / 'observation.json')
        report['receipt'] = receipt; report['observation'] = observation
        report['responses'] = responses
        expected = [item['path'] for item in responses]
        events = archive.get('events', [])
        report['archive'] = {'total': archive.get('total'), 'lastID': archive.get('lastID'), 'uncollected': archive.get('uncollected'), 'evicted': archive.get('evicted'), 'rejections': archive.get('rejections'), 'paths': [item['path'] for item in events]}
        assert archive.get('total') == archive.get('lastID') == len(responses), archive
        assert [item['id'] for item in events] == list(range(1, len(responses) + 1))
        assert [item['path'] for item in events] == expected and all(item['status'] == 404 and item['method'] == 'GET' for item in events)
        assert incomplete not in expected and incomplete not in [item['path'] for item in events]
        rejections = archive.get('rejections', {})
        assert sum(rejections.get(key, {}).get('count', 0) for key in ['http_incomplete', 'http_400', 'http_timeout']) >= 1, rejections
        assert archive.get('uncollected') == archive.get('evicted') == 0
        assert receipt.get('pending') == 0 and receipt.get('knownUncollected') == receipt.get('evicted') == 0
        assert receipt.get('pages', 0) >= math.ceil((len(responses) - report['preStopLastID']) / 128)
        assert receipt.get('elapsedMilliseconds', 999999) <= 550, receipt
        assert receipt.get('status') == 'confirmed' and receipt.get('sealed') and receipt.get('unconfirmedTail') is False, receipt
        assert observation.get('finalization') == 'confirmed' and observation.get('pending') == 0
        report['success'] = True
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
    finally:
        if held:
            held.close()
        try:
            bootout(run)
            if launcher and launcher.poll() is None:
                if str(binary) in process(launcher.pid):
                    launcher.terminate()
                launcher.wait(timeout=10)
            wait(lambda: not remaining(witnesses), 10)
            report['helpersGoneAfterCleanup'] = True
        except Exception as error:
            report['cleanupError'] = str(error); report['success'] = False
        log.close(); (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    if not report['success']:
        raise SystemExit(f"FAIL: {report.get('error', report.get('cleanupError'))}; {output / 'report.json'}")
    print(f"PASS: 末尾{options.tail_count}件・未完了Relay・全観測ページ・最終フェンス・保存・実VZ/FD回収; {output / 'report.json'}")


if __name__ == '__main__':
    main()
