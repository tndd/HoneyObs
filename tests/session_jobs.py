#!/usr/bin/env python3
"""GUI/VMを作らず、製品の2job所有と相互回収を実launchdで検査する。"""
import json
import fcntl
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid
from qa_registry import generated_app_path, register_app, require_cleanup

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test-results' / ('session-jobs-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
OUT.mkdir(mode=0o700, parents=True)
APP = generated_app_path(OUT)
EXE = APP / 'Contents/MacOS/HoneyObs'
HELPER = APP / 'Contents/Helpers/HoneyObsSession'
EXE.parent.mkdir(parents=True)
HELPER.parent.mkdir(parents=True)
(APP / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.honeyobs.session-jobs-fixture',
    'CFBundleName': 'HoneyObs Session Fixture',
    'CFBundleExecutable': 'HoneyObs',
    'CFBundlePackageType': 'APPL',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0',
}))
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
subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True, capture_output=True)
register_app(APP)

archive_probe = OUT / 'archive-probe'
subprocess.run(['swiftc', '-swift-version', '5', 'Sources/HoneyObs/SessionArchive.swift', 'tests/SessionArchiveRecoveryChecks.swift',
                '-o', str(archive_probe)], cwd=ROOT, check=True)

for fault in ['normal', 'client-kill', 'client-stop', 'monitor-kill', 'monitor-stop', 'cross-revoke', 'finish-delayed-ack', 'finish-no-ack', 'retention-recovery']:
    run = OUT / fault
    run.mkdir(mode=0o700)
    if fault == 'retention-recovery':
        # Foundation.DateのJSONは2001-01-01起点。UI保存lockを持たないfixtureでmonitorだけを検証する。
        (run / 'session-owner.json').write_text(json.dumps({'schema': 1, 'created': time.time() - 978307200 - 7200, 'closed': True}))
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
            elif fault in ['finish-delayed-ack', 'finish-no-ack', 'retention-recovery']:
                monitor = owner['ownerPID']
                current = command('/bin/ps', '-p', str(monitor), '-o', 'command=').stdout.strip()
                assert current.startswith(str(HELPER) + ' '), current
                os.kill(monitor, signal.SIGSTOP)
                time.sleep(.3)  # clientが最後の通常leaseを書いた後もmonitorからACKは返らない。
                (run / 'fixture-quit').touch()
                wait(lambda: read(run / 'finish-started.json').get('ready'))
                if fault == 'finish-delayed-ack':
                    time.sleep(.08)
                    assert alive(owner['clientPID']), '終端ACK前にclientがFDを閉じて退出しています'
                else:
                    wait(lambda: (run / 'finish-result.json').exists(), 1.5)
                    assert read(run / 'finish-result.json').get('acknowledged') is False
                    if fault == 'retention-recovery':
                        wait(lambda: not alive(owner['clientPID']))
                        with (run / '.recovery.lock').open('r+') as protection:
                            try:
                                fcntl.flock(protection, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            except BlockingIOError:
                                pass
                            else:
                                raise AssertionError('monitor結果保存前に回収lockを解放しています')
                        probe = command(str(archive_probe), '--probe', str(OUT))
                        assert probe.returncode == 0 and run.exists(), probe.stdout + probe.stderr
                        assert not (run / 'session-result.json').exists(), '遅いmonitor結果保存の条件を失っています'
                os.kill(monitor, signal.SIGCONT)
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
            if fault == 'retention-recovery':
                assert read(run / 'session-result.json').get('status') == 1
                REPORT['cases'][fault]['lateReceiptPersistedAfterClientDeath'] = True
            wrapper.wait(timeout=5)
            assert wrapper.returncode == (0 if fault in ['normal', 'finish-delayed-ack'] else 1), wrapper.returncode
            if fault in ['normal', 'finish-delayed-ack']:
                assert read(run / 'finish-result.json').get('acknowledged'), '終端ACKを確認できません'
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

# 同じ親の二つのrunを並行起動しても、他方の回収記録を共有しない。
parallel = []
try:
    for index in range(2):
        run = OUT / ('independent-' + str(index)); run.mkdir(mode=0o700)
        log = (run / 'launcher.log').open('w')
        wrapper = subprocess.Popen([str(EXE), '--test-mode', '--run-directory', str(run)], stdout=log, stderr=log)
        item = {'run': run, 'log': log, 'wrapper': wrapper, 'owner': {}}
        parallel.append(item)
        item['owner'] = wait(lambda: read(run / 'owner.json'), 15)
        wait(lambda: read(run / 'launcher-ready.json').get('ready'))
    assert len({item['owner']['ownerService'] for item in parallel}) == 2
    assert all(alive(item['owner'][key]) for item in parallel for key in ['ownerPID', 'clientPID'])
    assert all((item['run'] / '.session-registry').is_dir() for item in parallel)
    for item in parallel:
        (item['run'] / 'fixture-quit').touch()
        wait(lambda: gone(item['owner']), 10)
        item['wrapper'].wait(timeout=5)
        assert item['wrapper'].returncode == 0
    REPORT['cases']['independent-runs'] = {'twoSessionsAliveTogether': True, 'bothNormalExit': True, 'beforeTestCleanup': True}
    print('independent-runs: PASS', flush=True)
finally:
    for item in parallel:
        for key in ['clientService', 'ownerService']:
            if key in item['owner']:
                command('/bin/launchctl', 'bootout', item['owner'][key])
        if item['wrapper'].poll() is None:
            item['wrapper'].terminate()
            try:
                item['wrapper'].wait(timeout=12)
            except subprocess.TimeoutExpired:
                item['wrapper'].kill(); item['wrapper'].wait()
        item['log'].close()

require_cleanup()
(OUT / 'report.json').write_text(json.dumps(REPORT, ensure_ascii=False, indent=2))
print('実launchdの相互回収（GUI/VMなし）: PASS', OUT)
