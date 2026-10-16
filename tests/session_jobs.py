#!/usr/bin/env python3
"""GUI/VMを作らず、製品の2job所有と相互回収を実launchdで検査する。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test-results' / ('session-jobs-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
OUT.mkdir(mode=0o700, parents=True)
APP = OUT / 'HoneyObs.app'
EXE = APP / 'Contents/MacOS/HoneyObs'
HELPER = APP / 'Contents/Helpers/HoneyObsSession'
EXE.parent.mkdir(parents=True)
HELPER.parent.mkdir(parents=True)
REPORT = {'scope': '実launchd・製品socket認証とlease、GUI/VMなし', 'cases': {}}


def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=10)


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def wait(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if value := predicate():
            return value
        time.sleep(.04)
    raise AssertionError('2job検査の待機期限を超えました')


def alive(pid):
    result = command('/bin/ps', '-p', str(pid), '-o', 'stat=')
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')


def gone(owner):
    return (all(not alive(owner[key]) for key in ['ownerPID', 'clientPID'])
            and all(command('/bin/launchctl', 'print', owner[key]).returncode != 0 for key in ['ownerService', 'clientService'])
            and not Path(owner['socketDirectory']).exists())


for sources, target in [(['Sources/HoneyObs/SessionOwnership.swift', 'tests/SessionJobFixture.swift'], EXE),
                        (['Sources/HoneyObs/SessionOwnership.swift', 'Sources/SessionMonitor/Main.swift'], HELPER)]:
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', *sources, '-o', str(target)], cwd=ROOT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)

for fault in ['normal', 'client-kill', 'client-stop', 'monitor-kill', 'monitor-stop', 'cross-revoke']:
    run = OUT / fault
    run.mkdir(mode=0o700)
    owner = {}
    with (run / 'launcher.log').open('w') as log:
        wrapper = subprocess.Popen([str(EXE), '--test-mode', '--run-directory', str(run)], stdout=log, stderr=log)
        try:
            owner = wait(lambda: read(run / 'owner.json'), 15)
            wait(lambda: read(run / 'launcher-ready.json').get('ready'))
            assert owner['ownerPID'] != wrapper.pid and owner['clientPID'] != wrapper.pid
            start = time.monotonic()
            if fault == 'normal':
                (run / 'fixture-quit').touch()
            elif fault == 'cross-revoke':
                (run / 'fixture-revoke').touch()
                os.kill(owner['ownerPID'], signal.SIGTERM)
            else:
                key = 'ownerPID' if fault.startswith('monitor') else 'clientPID'
                executable = HELPER if key == 'ownerPID' else EXE
                current = command('/bin/ps', '-p', str(owner[key]), '-o', 'command=').stdout.strip()
                assert current.startswith(str(executable) + ' '), current
                os.kill(owner[key], signal.SIGKILL if fault.endswith('kill') else signal.SIGSTOP)
            wait(lambda: gone(owner), 10)
            REPORT['cases'][fault] = {'allGoneWithin': round(time.monotonic() - start, 3), 'beforeTestCleanup': True}
            wrapper.wait(timeout=5)
            assert wrapper.returncode == (0 if fault == 'normal' else 1), wrapper.returncode
            print(fault + ': PASS', flush=True)
        except BaseException as error:
            REPORT['cases'][fault] = {'failed': repr(error), 'owner': owner,
                                      'processesBeforeCleanup': {key: command('/bin/ps', '-p', str(owner.get(key, -1)), '-o', 'pid=,stat=,command=').stdout.strip()
                                                                for key in ['ownerPID', 'clientPID']}}
            (OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
            raise
        finally:
            # 成否の証拠を採取した後だけ掃除する。
            for key in ['clientService', 'ownerService']:
                if key in owner:
                    command('/bin/launchctl', 'bootout', owner[key])
            if wrapper.poll() is None:
                wrapper.terminate()
                try:
                    wrapper.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    wrapper.kill(); wrapper.wait()

(OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
print('実launchdの相互回収（GUI/VMなし）: PASS', OUT)
