#!/usr/bin/env python3
"""私有launchd job、実VZ/XPC所有、故障直後のOS回収を外部から検証する。"""
import argparse
import ctypes
import json
import os
import pathlib
import re
import select
import signal
import socket
import subprocess
import threading
import time

options_parser = argparse.ArgumentParser()
options_parser.add_argument('--egress-fixture', action='store_true', help='EGRESS_TESTING専用appの固定loopback fixtureで通信VMも検証する')
options_parser.add_argument('--case', action='append', default=[], help='指定した故障だけ再検証する')
OPTIONS = options_parser.parse_args()
ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get('HONEYOBS_APP', ROOT / 'build/HoneyObs.app')).resolve()
OUT = ROOT / 'test-results' / ('session-ownership-' + time.strftime('%Y%m%d-%H%M%S'))
OUT.mkdir(mode=0o700, parents=True)
REPORT = {'actualVM': True, 'externalTunnel': False, 'actualEgressVM': OPTIONS.egress_fixture, 'cases': {},
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


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ['flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved']] + [
        ('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ['nfiles', 'pgid', 'jobc', 'tty', 'tpgid']] + [
        ('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


LIBPROC = ctypes.CDLL('/usr/lib/libproc.dylib')
LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_pidinfo.restype = ctypes.c_int


def kernel_info(pid):
    info = BSDInfo()
    return info if LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info) else None


def alive(pid):
    info = kernel_info(pid)
    return info is not None and info.status != 5  # SZOMB has already stopped executing.


_self = kernel_info(os.getpid())
assert _self is not None and _self.pid == os.getpid() and _self.uid == os.getuid() and _self.pgid == os.getpgrp()
assert abs(time.time() - _self.start_sec) < 60, 'proc_bsdinfo ABIまたは時計を確認できません'

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


def helpers(client, run, allow_empty=False):
    result = command('/bin/launchctl', 'print', 'pid/' + str(client))
    assert result.returncode == 0 and f'creator = HoneyObs[{client}]' in result.stdout, result.stdout
    (run / 'xpc-owner.txt').write_text(result.stdout)
    owned = re.findall(r'^\s+(\d+)\s+\S+\s+(com\.apple\.Virtualization\.VirtualMachine\.[A-F0-9-]+)\s*$', result.stdout, re.M)
    if not allow_empty:
        assert owned, '実VMのUUID付きXPCサービスをOS所有ドメインで確認できません'
    entries = []
    for pid, service in owned:
        pid = int(pid)
        identity = process(pid)
        if allow_empty and '/Virtualization.framework/' not in identity:
            return []  # launchd publishes the service while xpcproxy is still exec'ing it.
        assert '/Virtualization.framework/' in identity, identity
        info = kernel_info(pid)
        assert info is not None
        entries.append({'pid': pid, 'service': service, 'identity': identity,
                        'kernelBirth': f'{info.start_sec}:{info.start_usec}',
                        'birth': command('/bin/ps', '-p', str(pid), '-o', 'lstart=').stdout.strip(),
                        'command': command('/bin/ps', '-p', str(pid), '-o', 'command=').stdout.strip()})
    return entries


EXE = APP / 'Contents/MacOS/HoneyObs'

faults = ['normal-stop', 'client-kill', 'monitor-kill', 'client-stop', 'monitor-stop', 'startup-stop',
          'decoy-helper-kill', 'decoy-helper-stop']
if OPTIONS.egress_fixture:
    faults += ['egress-helper-kill', 'egress-helper-stop']
if OPTIONS.case:
    assert set(OPTIONS.case) <= set(faults), OPTIONS.case
    faults = [case for case in faults if case in OPTIONS.case]
for fault in faults:
    run = OUT / fault
    run.mkdir(mode=0o700)
    held = None
    launch = [str(EXE), '--test-mode', '--headless', '--run-directory', str(run)]
    launch += ['--public', '--test-egress-fixture'] if OPTIONS.egress_fixture else ['--local-origin']
    wrapper = subprocess.Popen(launch,
                               stdout=(run / 'launcher.log').open('w'), stderr=subprocess.STDOUT)
    owner = {}; witness = []; timeline = {}; resource_elapsed = None; start = None
    stop_observer = threading.Event(); observer = None; late = {}; late_observer = None
    try:
        owner = wait(lambda: read(run / 'owner.json'), 15)
        client, monitor = owner['clientPID'], owner['ownerPID']
        assert client != monitor and owner.get('jobBodyIsVZOwner')
        state = wait(lambda: s if (s := read(run / 'state.json')).get('active') else None, 20)
        witness = []; decoy_service = None
        if OPTIONS.egress_fixture and fault != 'startup-stop':
            def decoy_before_egress():
                if read(run / 'state.json').get('egressVMPresent'):
                    raise AssertionError('egress作成前のdecoy XPC所有snapshotを採取できませんでした')
                entries = helpers(client, run, allow_empty=True)
                return entries if len(entries) == 1 else None
            decoy_snapshot = wait(decoy_before_egress, 15)
            decoy_service = decoy_snapshot[0]['service']
            (run / 'decoy-before-egress.txt').write_text((run / 'xpc-owner.txt').read_text())
        if fault != 'startup-stop':
            state = wait(lambda: s if (s := read(run / 'state.json')).get('originPort') and
                         (not OPTIONS.egress_fixture or (s.get('egressVMPresent') and s.get('egressHealthy'))) else None, 50)
            port, host = state['originPort'], read(run / 'test-origin.json')['host']
            witness = helpers(client, run)
            assert len(witness) >= (2 if OPTIONS.egress_fixture else 1), witness
            for entry in witness:
                entry['role'] = 'decoy' if not OPTIONS.egress_fixture or entry['service'] == decoy_service else 'egress'
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
        start = time.monotonic(); timeline = {}
        def observe_stop():
            while not stop_observer.is_set():
                elapsed = round(time.monotonic() - start, 3)
                if read(run / 'state.json').get('stopping') and 'stopRequestedWithin' not in timeline:
                    timeline['stopRequestedWithin'] = elapsed
                for key, pid in [('clientGoneWithin', client), ('monitorGoneWithin', monitor)] + [(entry['role'] + 'HelperGoneWithin', entry['pid']) for entry in witness]:
                    if key not in timeline and not alive(pid):
                        timeline[key] = elapsed
                time.sleep(.025)
        observer = threading.Thread(target=observe_stop, daemon=True); observer.start()
        if '-helper-' in fault:
            role = fault.split('-')[0]
            target = next(entry for entry in witness if entry['role'] == role)
            current = command('/bin/ps', '-p', str(target['pid']), '-o', 'command=').stdout.strip()
            current_birth = command('/bin/ps', '-p', str(target['pid']), '-o', 'lstart=').stdout.strip()
            info = kernel_info(target['pid'])
            assert info is not None and f'{info.start_sec}:{info.start_usec}' == target['kernelBirth']
            assert current == target['command'] and current_birth == target['birth'] and '/Virtualization.framework/' in current, target
            os.kill(target['pid'], signal.SIGKILL if fault.endswith('kill') else signal.SIGSTOP)
        elif fault == 'normal-stop':
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
        if '-helper-' in fault:
            def probe_after_expiry():
                time.sleep(max(0, 3.25 - (time.monotonic() - start)))
                late['attemptedAt'] = round(time.monotonic() - start, 3)
                try:
                    with socket.create_connection(('127.0.0.1', port), .5) as probe:
                        probe.settimeout(2)
                        probe.sendall(f'GET /qa-helper-after-expiry HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
                        try:
                            response = probe.recv(100)
                        except (ConnectionResetError, TimeoutError):
                            response = b''
                        late['denied'] = response == b''
                except OSError:
                    late['denied'] = True
            late_observer = threading.Thread(target=probe_after_expiry, daemon=True); late_observer.start()
        cutoff = None
        if held:
            held.settimeout(6)
            try:
                content = held.recv(100)
            except ConnectionResetError:
                content = b''
            cutoff = time.monotonic() - start
            assert content == b'' and cutoff < 6, (fault, cutoff, content)
        cooperative_helper_stop = False
        if '-helper-' in fault:
            def helper_recovered():
                final = read(run / 'state.json')
                return all(not alive(entry['pid']) for entry in witness) and (not alive(client) or
                       (final.get('shutdownComplete') and not final.get('vmPresent') and not final.get('egressVMPresent')))
            wait(helper_recovered, 17)
            resource_elapsed = time.monotonic() - start
            cooperative_helper_stop = alive(client)
            if cooperative_helper_stop:
                assert closed(port) and alive(monitor)
                signal_owned(client, '--session-client', signal.SIGTERM)
        elif fault == 'normal-stop':
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
        if '-helper-' not in fault:
            resource_elapsed = time.monotonic() - start
        stop_observer.set(); observer.join(timeout=1)
        wrapper.wait(timeout=12)
        if fault in ['normal-stop', 'startup-stop']:
            assert wrapper.returncode == 0, wrapper.returncode
        wait(lambda: command('/bin/launchctl', 'print', service).returncode != 0)
        monitor_service = owner.get('ownerService')
        assert monitor_service, 'monitor OS job identityが所有記録にありません'
        wait(lambda: command('/bin/launchctl', 'print', monitor_service).returncode != 0)
        wait(lambda: not alive(client) and not alive(monitor))
        assert all(not alive(entry['pid']) for entry in witness)
        socket_directory = owner.get('socketDirectory')
        assert socket_directory and not pathlib.Path(socket_directory).exists(), '故障後も管理socketが残っています'
        all_gone_elapsed = time.monotonic() - start
        if late_observer:
            late_observer.join(timeout=6)
            assert not late_observer.is_alive() and late.get('denied') and late['attemptedAt'] >= 3.2, late
        REPORT['cases'][fault] = {'existingSocketClosedWithin': round(cutoff, 3) if cutoff is not None else None,
                                  'operationalResourcesRecoveredWithin': round(resource_elapsed, 3),
                                  'allRecoveredWithin': round(all_gone_elapsed, 3), 'bothJobsRemoved': True, 'newAfterExpiry': late,
                                  'stopRequestedWithin': timeline.get('stopRequestedWithin'),
                                  'recoveredAfterStopRequest': round(resource_elapsed - timeline['stopRequestedWithin'], 3) if 'stopRequestedWithin' in timeline else None,
                                  'cooperativeHelperStop': cooperative_helper_stop, 'timeline': timeline,
                                  'directVZOwnerGone': True, 'monitorGone': True, 'xpcHelpersGone': True,
                                  'xpcOwnershipWitness': witness, 'socketGone': True, 'beforeTestCleanup': True}
        print(fault + ': PASS', flush=True)
    except BaseException as error:
        REPORT['cases'][fault] = {'failed': repr(error), 'owner': owner, 'state': read(run / 'state.json'),
                                  'membersBeforeCleanup': members(owner.get('clientPGID', -1)),
                                  'clientAliveBeforeCleanup': alive(owner['clientPID']) if owner else None,
                                  'monitorAliveBeforeCleanup': alive(owner['ownerPID']) if owner else None,
                                  'helpersBeforeCleanup': [dict(entry, alive=alive(entry['pid'])) for entry in witness],
                                  'elapsedAtFailure': round(time.monotonic() - start, 3) if start else None,
                                  'operationalResourcesRecoveredWithin': round(resource_elapsed, 3) if resource_elapsed is not None else None,
                                  'timeline': timeline,
                                  'socketExistsBeforeCleanup': pathlib.Path(owner['socketDirectory']).exists() if owner.get('socketDirectory') else None}
        (OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
        raise
    finally:
        stop_observer.set()
        if observer:
            observer.join(timeout=1)
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
