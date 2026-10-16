#!/usr/bin/env python3
"""私有launchd job、実VZ/XPC所有、故障直後のOS回収を外部から検証する。"""
import json
import os
import pathlib
import re
import select
import signal
import socket
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get('HONEYOBS_APP', ROOT / 'build/HoneyObs.app')).resolve()
OUT = ROOT / 'test-results' / ('session-ownership-' + time.strftime('%Y%m%d-%H%M%S'))
OUT.mkdir(mode=0o700, parents=True)
REPORT = {'actualVM': True, 'externalTunnel': False, 'cases': {},
          'unverified': ['owner と client を含む全監視処理の同時 SIGSTOP', '実スリープ・ログアウト', '独立外部経路']}


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def wait(predicate, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('状態確認の待機期限を超えました')


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=10)


def process(pid):
    result = command('/bin/ps', '-p', str(pid), '-o', 'pid=,ppid=,pgid=,stat=,lstart=,command=')
    return result.stdout.strip()


def alive(pid):
    result = command('/bin/ps', '-p', str(pid), '-o', 'stat=')
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')


def members(pgid):
    result = command('/bin/ps', '-axo', 'pid=,pgid=,stat=,command=')
    return [line.strip() for line in result.stdout.splitlines()
            if len((parts := line.split(None, 3))) >= 4 and parts[1] == str(pgid) and not parts[2].startswith('Z')]


def closed(port):
    try:
        with socket.create_connection(('127.0.0.1', port), .2):
            return False
    except OSError:
        return True


def signal_owned(pid, expected, sig):
    # Only processes observed inside this exact executable's session are signalled.
    current = command('/bin/ps', '-p', str(pid), '-o', 'command=').stdout.strip()
    assert str(EXE) in current and expected in current, (pid, current, expected)
    os.kill(pid, sig)


def helpers(client, run):
    result = command('/bin/launchctl', 'print', 'pid/' + str(client))
    assert result.returncode == 0 and f'creator = HoneyObs[{client}]' in result.stdout, result.stdout
    (run / 'xpc-owner.txt').write_text(result.stdout)
    owned = re.findall(r'^\s+(\d+)\s+\S+\s+(com\.apple\.Virtualization\.VirtualMachine\.[A-F0-9-]+)\s*$', result.stdout, re.M)
    assert owned, '実VMのUUID付きXPCサービスをOS所有ドメインで確認できません'
    entries = []
    for pid, service in owned:
        pid = int(pid)
        identity = process(pid)
        assert '/Virtualization.framework/' in identity, identity
        entries.append({'pid': pid, 'service': service, 'identity': identity})
    return entries


EXE = APP / 'Contents/MacOS/HoneyObs'

for fault in ['normal-stop', 'client-kill', 'monitor-kill', 'client-stop', 'monitor-stop', 'startup-stop']:
    run = OUT / fault
    run.mkdir(mode=0o700)
    held = None
    wrapper = subprocess.Popen([str(EXE), '--test-mode', '--headless', '--local-origin', '--run-directory', str(run)],
                               stdout=(run / 'launcher.log').open('w'), stderr=subprocess.STDOUT)
    owner = {}
    try:
        owner = wait(lambda: read(run / 'owner.json'), 15)
        client, monitor = owner['clientPID'], owner['ownerPID']
        assert client != monitor and owner.get('jobBodyIsVZOwner')
        state = wait(lambda: s if (s := read(run / 'state.json')).get('active') else None, 20)
        witness = []
        if fault != 'startup-stop':
            state = wait(lambda: s if (s := read(run / 'state.json')).get('originPort') else None, 40)
            port, host = state['originPort'], read(run / 'test-origin.json')['host']
            witness = helpers(client, run)
            held = socket.create_connection(('127.0.0.1', port), 1)
            held.sendall(f'POST /login HTTP/1.1\r\nHost: {host}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx'.encode())
            time.sleep(.1)
            assert not select.select([held], [], [], 0)[0], '故障注入前に既存接続が終了しています'
        spec = __import__('plistlib').loads((run / 'session-job.plist').read_bytes())
        assert not spec['KeepAlive'] and spec['RunAtLoad'] and not spec['AbandonProcessGroup'] and spec['ExitTimeOut'] == 1
        assert not any(key in spec for key in ['StartInterval', 'StartCalendarInterval', 'MachServices', 'Sockets'])
        service = owner.get('clientService') or 'gui/' + str(os.getuid()) + '/' + owner['label']
        job = command('/bin/launchctl', 'print', service)
        assert job.returncode == 0 and re.search(r'(?m)^\s*pid = ' + str(client) + '$', job.stdout), job.stdout
        start = time.monotonic()
        if fault == 'normal-stop':
            (run / 'command').write_text('stop')
        elif fault == 'startup-stop':
            signal_owned(client, '--session-client', signal.SIGTERM)
        elif fault.startswith('client-'):
            signal_owned(client, '--session-client', signal.SIGKILL if fault.endswith('kill') else signal.SIGSTOP)
        else:
            # Dedicated helper is independently owned by its own transient job.
            current = command('/bin/ps', '-p', str(monitor), '-o', 'command=').stdout.strip()
            assert str(APP / 'Contents/Helpers/HoneyObsSession') in current and '--monitor-job' in current, current
            os.kill(monitor, signal.SIGKILL if fault.endswith('kill') else signal.SIGSTOP)
        cutoff = None
        if held:
            held.settimeout(6)
            try:
                content = held.recv(100)
            except ConnectionResetError:
                content = b''
            cutoff = time.monotonic() - start
            assert content == b'' and cutoff < 6, (fault, cutoff, content)
        if fault == 'normal-stop':
            final = wait(lambda: s if (s := read(run / 'state.json')).get('shutdownComplete') else None)
            assert not final['vmPresent'] and final['canStart'] and closed(port), final
            wait(lambda: all(not alive(entry['pid']) for entry in witness))
            assert alive(client) and alive(monitor), '停止後の操作画面とOS監視は保持する必要があります'
            signal_owned(client, '--session-client', signal.SIGTERM)
        else:
            wait(lambda: not alive(client) and not alive(monitor) and all(not alive(entry['pid']) for entry in witness),
                 max(.1, 8 - (time.monotonic() - start)))
            if fault != 'startup-stop':
                assert closed(port), 'OS回収後も入口が開いています'
        wrapper.wait(timeout=12)
        wait(lambda: command('/bin/launchctl', 'print', service).returncode != 0)
        monitor_service = owner.get('ownerService')
        assert monitor_service, 'monitor OS job identityが所有記録にありません'
        wait(lambda: command('/bin/launchctl', 'print', monitor_service).returncode != 0)
        wait(lambda: not alive(client) and not alive(monitor))
        assert all(not alive(entry['pid']) for entry in witness)
        socket_directory = owner.get('socketDirectory')
        assert socket_directory and not pathlib.Path(socket_directory).exists(), '故障後も管理socketが残っています'
        REPORT['cases'][fault] = {'existingSocketClosedWithin': round(cutoff, 3) if cutoff is not None else None,
                                  'allRecoveredWithin': round(time.monotonic() - start, 3), 'bothJobsRemoved': True,
                                  'directVZOwnerGone': True, 'monitorGone': True, 'xpcHelpersGone': True,
                                  'xpcOwnershipWitness': witness, 'socketGone': True, 'beforeTestCleanup': True}
        print(fault + ': PASS', flush=True)
    except BaseException as error:
        REPORT['cases'][fault] = {'failed': repr(error), 'owner': owner, 'state': read(run / 'state.json'),
                                  'membersBeforeCleanup': members(owner.get('clientPGID', -1))}
        (OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
        raise
    finally:
        if held:
            held.close()
        # Cleanup is after evidence collection and never a success witness.
        for field in ['clientService', 'ownerService']:
            if owner.get(field):
                command('/bin/launchctl', 'bootout', owner[field])
        if wrapper.poll() is None:
            wrapper.terminate()
            try:
                wrapper.wait(timeout=12)
            except subprocess.TimeoutExpired:
                wrapper.kill(); wrapper.wait()

(OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
print('実VMのOS所有・既存接続遮断・job/XPC/IPC回収: PASS', OUT)
