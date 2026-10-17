#!/usr/bin/env python3
"""実NSMenuの追跡中も製品WKWebView・観測VM・所有監視の応答が進むか検査する。"""
import argparse
import ctypes
import json
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import time
import uuid

from app_background import command, fresh, process, read, wait
from integration import bootout_owned, xpc_helpers
from qa_registry import generated_app_path, register_app, require_cleanup

ROOT = Path(__file__).resolve().parent.parent


def birth(pid):
    data = ctypes.create_string_buffer(136)
    size = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidinfo(pid, 3, 0, data, len(data))
    if size != len(data):
        return None
    seconds, micros = struct.unpack_from('=QQ', data.raw, 120)
    return f'{seconds}:{micros}'


def owned(owner):
    for role in ['owner', 'client']:
        pid = owner[role + 'PID']
        assert birth(pid) == owner[role + 'Birth'], (role, pid, birth(pid))
        result = subprocess.run(['/bin/launchctl', 'print', owner[role + 'Service']], capture_output=True, text=True, timeout=3)
        assert result.returncode == 0 and re.search(r'^\s*pid = ' + str(pid) + r'\s*$', result.stdout, re.M), result.stdout


def request(port, host, path):
    with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
        connection.sendall(f'GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
        response = b''
        while True:
            value = connection.recv(4096)
            if not value:
                break
            response += value
        assert b' 404 ' in response.split(b'\r\n', 1)[0] and response.endswith(b'Not found\n'), response


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/Applications.noindex/HoneyObs.app')
    args = parser.parse_args()
    output = ROOT / 'test-results' / ('menu-tracking-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    output.mkdir(mode=0o700, parents=True)
    app = generated_app_path(output / 'private')
    shutil.copytree(args.app.resolve(), app)
    run = output / 'run'; run.mkdir(mode=0o700)
    report = {'success': False, 'externalPublication': False, 'actualNSMenu': True, 'actualWKWebView': True, 'actualObservationVM': True}
    owner, helpers, wrapper = {}, [], None
    try:
        with (run / 'launcher.log').open('w') as log:
            register_app(app)
            wrapper = subprocess.Popen([str(app / 'Contents/MacOS/HoneyObs'), '--test-mode', '--ui-dashboard-smoke', '--run-directory', str(run)], stdout=log, stderr=log)
            native = wait(lambda: read(run / 'background-state.json'), 20)
            owner = wait(lambda: read(run / 'owner.json'))
            assert native['pid'] == owner['clientPID']
            command(run, 'local-origin')
            state = wait(lambda: s if (s := read(run / 'state.json')).get('phase') == 'ローカル準備完了' else None, 45)
            port, host = state['originPort'], wait(lambda: read(run / 'test-origin.json').get('host'))
            baseline = wait(lambda: fresh(run))
            helpers = xpc_helpers(owner['clientPID'])
            report.update({'owner':owner, 'xpcHelpers':helpers})
            owned(owner)
            command(run, 'track-menu')
            trace = wait(lambda: t if (t := read(run / 'menu-tracking.json')).get('samples') else None, 10)
            requests = []
            end = time.monotonic() + 8
            while not trace.get('finished') and time.monotonic() < end:
                sample = trace['samples'][-1]
                if sample['mode'] == 'NSEventTrackingRunLoopMode' and sample['elapsed'] < 3.9:
                    owned(owner)
                    request(port, host, '/menu-tracking-' + str(len(requests)))
                    requests.append({'menuElapsed': sample['elapsed'], 'mode': sample['mode'], 'status': 404})
                time.sleep(.25)
                trace = read(run / 'menu-tracking.json')
            assert trace.get('finished') and trace.get('cancelledByTimer'), trace
            assert 4.1 <= trace['duration'] <= 6, trace
            tracked = [s for s in trace['samples'] if s['mode'] == 'NSEventTrackingRunLoopMode']
            assert len(tracked) >= 12 and tracked[-1]['elapsed'] >= 3.8, tracked
            for sample in tracked:
                now = sample['safetyNow']
                assert sample['active'] and sample['permitValid'] and sample['permitDeadline'] > now, sample
                assert 0 <= now - sample['guestConfirmedAt'] < 3 and 0 <= now - sample['uiConfirmedAt'] < 3, sample
            for key in ['uiConfirmedAt', 'guestConfirmedAt']:
                assert len({s[key] for s in tracked}) >= 3 and tracked[-1][key] - baseline[key] >= 3, (key, tracked)
            assert len(requests) >= 8 and requests[-1]['menuElapsed'] >= 3.4, requests
            owned(owner); request(port, host, '/menu-tracking-after')
            report.update({'owner':owner, 'menu':trace, 'requestsDuringMenu':requests, 'responseAfterMenu':404, 'xpcHelpers':helpers})
            command(run, 'stop'); wait(lambda: read(run / 'state.json').get('shutdownComplete'), 15)
            command(run, 'quit'); wrapper.wait(timeout=15)
            assert wrapper.returncode == 0, wrapper.returncode
            wait(lambda: all(birth(owner[key]) is None for key in ['ownerPID','clientPID']) and all(not process(pid) for pid in helpers), 10)
            report['allOwnedProcessesGoneBeforeCleanup'] = True
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        if wrapper and wrapper.poll() is None:
            bootout_owned(run)
            wrapper.terminate()
            try: wrapper.wait(timeout=12)
            except subprocess.TimeoutExpired: wrapper.kill(); wrapper.wait()
        if not report.get('allOwnedProcessesGoneBeforeCleanup'):
            (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    try:
        require_cleanup()
    except Exception as error:
        report['error'] = str(error)
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        raise
    report['success'] = True
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('実NSMenu追跡4.2秒・UI/guest freshness・所有job維持・追跡中/後HTTP・実VM回収: PASS', output)


if __name__ == '__main__':
    main()
