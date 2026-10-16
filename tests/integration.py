#!/usr/bin/env python3
"""実VM・実公開経路を通す検証。公開したプロセスは失敗時も回収する。"""
import argparse
import re
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'build/HoneyObs.app/Contents/MacOS/HoneyObs'
OUT = ROOT / 'test-results' / ('verification-' + time.strftime('%Y%m%d-%H%M%S'))


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def wait(predicate, seconds=35):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.3)
    raise AssertionError('期限内に条件が成立しませんでした')


def alive(pid):
    if not pid:
        return False
    p = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    return bool(p.stdout.strip()) and not p.stdout.strip().startswith('Z')


def xpc_helpers(pid):
    domain = subprocess.run(['/bin/launchctl', 'print', 'pid/' + str(pid)], capture_output=True, text=True)
    assert domain.returncode == 0 and f'creator = HoneyObs[{pid}]' in domain.stdout, domain.stdout
    owned = re.findall(r'^\s+(\d+)\s+\S+\s+com\.apple\.Virtualization\.VirtualMachine\.[A-F0-9-]+\s*$', domain.stdout, re.M)
    assert owned, '実VMのXPC所有を確認できません'
    return [int(value) for value in owned]


def bootout_owned(directory):
    owner = read(directory / 'owner.json')
    for field in ['clientService', 'ownerService']:
        service = owner.get(field)
        if service:
            assert service.startswith('gui/' + str(os.getuid()) + '/local.honeyobs.'), service
            subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)


def curl(url, *args):
    p = subprocess.run(['curl', '-4', '--http1.1', '--silent', '--show-error', '--max-time', '12',
                        '-w', '\n%{http_code}', *args, url], capture_output=True)
    body, _, status = p.stdout.rpartition(b'\n')
    return int(status or 0), body, p.returncode


class Session:
    def __init__(self, name, public=False, local_origin=False):
        self.directory = OUT / name
        self.directory.mkdir(mode=0o700, parents=True)
        self.log = (self.directory / 'app.log').open('w')
        self.canary = socket.socket()
        self.canary.bind(('127.0.0.1', 0))
        self.canary.listen(1)
        self.canary_port = self.canary.getsockname()[1]
        targets = [f'127.0.0.1:{self.canary_port}', '[::1]:80']
        ip = subprocess.run(['ipconfig', 'getifaddr', 'en0'], capture_output=True, text=True).stdout.strip()
        if ip:
            targets.append(f'{ip}:{self.canary_port}')
        env = dict(os.environ, HONEYOBS_PROBE_TARGETS=','.join(targets))
        command = [str(APP), '--test-mode', '--headless', '--run-directory', str(self.directory)]
        if public:
            command.append('--public')
        if local_origin:
            command.append("--local-origin")
        self.vz_helpers = []
        self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT, env=env)

    def state(self):
        value = read(self.directory / 'state.json')
        if value.get('phase') in ('エラー', '停止失敗'):
            raise AssertionError(value.get('detail'))
        if self.process.poll() is not None:
            raise AssertionError('アプリが終了しました: ' + str(self.process.returncode))
        return value

    def ready(self, public=False):
        accepted = ['公開中', '公開URL取得済み'] if public else ['ローカル準備完了']
        state = wait(lambda: s if (s := self.state()).get('phase') in accepted else None, 240 if public else 40)
        self.vz_helpers = xpc_helpers(state['pid'])
        return state

    def command(self, name):
        (self.directory / 'command').write_text(name)

    def cleanup(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                bootout_owned(self.directory)
                self.process.kill(); self.process.wait()
        bootout_owned(self.directory)
        self.canary.close()
        self.log.close()


def isolation(session):
    data = wait(lambda: read(session.directory / 'isolation.json'))
    assert data['uid'] == 65534, data
    assert data['interfaces'] == ['lo'], data
    assert 'read-only file system' in data['rootWrite'], data
    assert data['probes'] and all(v != 'CONNECTED' for v in data['probes'].values()), data
    assert 'network is unreachable' in data['probes']['1.1.1.1:443'], data
    assert 'network is unreachable' in data['probes'][f'127.0.0.1:{session.canary_port}'], data
    assert data['mountReadError'] == '<nil>', data
    assert 'virtiofs' not in data['mounts'], data
    assert f'127.0.0.1:{session.canary_port}' in data['probes'], data
    return {'uid': data['uid'], 'interfaces': data['interfaces'], 'blockedProbes': len(data['probes']),
            'rootReadOnly': True, 'externalAndHostNetworkUnreachable': True, 'noSharedFilesystem': True,
            'routeReadError': data['routeReadError']}


def stopped(session, state, crash=False):
    assert session.vz_helpers, '停止前の実VM所有証拠がありません'
    wait(lambda: all(not alive(pid) for pid in session.vz_helpers), 9)
    try:
        sock = socket.create_connection(('127.0.0.1', state['originPort']), timeout=1)
    except OSError:
        pass
    else:
        sock.close()
        raise AssertionError('停止後もローカル入口が開いています')
    status, body, _ = curl(state['url'] + '/honeyobs-test-after-stop')
    assert body != b'Not found\n' and body != b'Authentication failed\n', (status, body[:100])
    return {'originClosed': True, 'ownedVZHelpersExited': True,
            'publicDecoyUnavailable': True, 'publicStatusAfterStop': status, 'crash': crash}


def local_test():
    session = Session('local')
    try:
        session.ready()
        result = isolation(session)
        session.command('stop')
        wait(lambda: session.state().get('shutdownComplete') is True)
        assert session.state()['vmPresent'] is False
        return result
    finally:
        session.cleanup()


def public_test():
    session = Session('public', public=True)
    try:
        state = session.ready(public=True)
        result = {'isolation': isolation(session)}
        url = state['url']
        status, trace, _ = curl(url + '/cdn-cgi/trace')
        assert status == 200, status
        ip = next(line[3:].decode() for line in trace.splitlines() if line.startswith(b'ip='))
        path = '/honeyobs-test-' + uuid.uuid4().hex
        status, body, rc = curl(url + path + '?password=DO_NOT_STORE', '-H', 'X-Forwarded-For: 198.51.100.77')
        assert (status, body, rc) == (404, b'Not found\n', 0), (status, body[:200], rc)
        event = wait(lambda: next((e for e in (read(session.directory / 'events.json').get('events') or []) if e['path'] == path), None))
        assert event['ip'] == ip, 'トレースの送信元と観測IPが不一致'
        assert 'DO_NOT_STORE' not in (session.directory / 'events.json').read_text()
        blocked_path = '/honeyobs-test-blocked-' + uuid.uuid4().hex
        status, body, _ = curl(url + blocked_path, '-H', 'CF-Connecting-IP: 203.0.113.55')
        assert status == 403 and b'1000' in body, (status, body[:100])
        time.sleep(2)
        assert not any(e['path'] == blocked_path for e in read(session.directory / 'events.json').get('events', []))
        status, _, _ = curl(url + '/login', '-d', 'password=DO_NOT_STORE')
        assert status == 401, status
        status, _, _ = curl(url + '/upload', '-d', 'x' * 9000)
        assert status == 413, status
        status, _, _ = curl(f"http://127.0.0.1:{state['originPort']}/", '-H', 'CF-Connecting-IP: 203.0.113.55')
        assert status == 403, status
        result['transport'] = {'publicHTTPS': True, 'vmResponse': True, 'ipMatchesEdgeTrace': True,
                               'xffSpoofIgnored': True, 'cfIPSpoofBlockedAtEdge': True, 'queryNotStored': True, 'bodyLimit413': True,
                               'localBypass403': True, 'loginAlways401': True}
        session.command('stop')
        wait(lambda: session.state().get('shutdownComplete') is True)
        result['normalStop'] = stopped(session, state)
        return result
    finally:
        session.cleanup()


def lifecycle_test(name, crash):
    session = Session(name + '-public', public=True)
    try:
        state = session.ready(public=True)
        if crash:
            target = state['pid']
            commandline = subprocess.check_output(['ps', '-p', str(target), '-o', 'command='], text=True).strip()
            assert commandline.startswith(str(APP)) and '--session-client' in commandline, commandline
            os.kill(target, signal.SIGKILL)
            session.process.wait(timeout=8)
        else:
            session.command('simulate-sleep')
            wait(lambda: session.state().get('shutdownComplete') is True)
            assert session.state()['detail'] == 'スリープ通知'
        return stopped(session, state, crash=crash)
    finally:
        session.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--local', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True)
    report = {'actualSleep': 'ユーザー指定により未実施。通知ハンドラの検証とは区別する。'}
    try:
        report['local'] = local_test()
        print('ローカルVMと隔離: PASS', flush=True)
        if not args.local:
            report['public'] = public_test()
            print('実公開・IP・通常停止: PASS', flush=True)
            report['forceQuit'] = lifecycle_test('force-quit', True)
            print('強制終了とトンネル回収: PASS', flush=True)
            report['sleepNotificationOnly'] = lifecycle_test('sleep-notification', False)
            print('スリープ通知ハンドラ: PASS（実スリープは未検証）', flush=True)
    except Exception as exc:
        report['failure'] = str(exc)
        raise
    finally:
        (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print('検証記録:', OUT, flush=True)


if __name__ == '__main__':
    main()
