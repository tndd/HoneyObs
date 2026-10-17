#!/usr/bin/env python3
"""実NSMenuのeventTracking中も製品SessionClientのleaseが続くことをVMなしで検証する。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid
from qa_registry import register_app, require_cleanup

parser = argparse.ArgumentParser()
parser.add_argument('--expect-menu-failure', action='store_true', help='修正前の再現証拠だけを採取する')
options = parser.parse_args()
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test-results' / ('menu-tracking-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
APP = OUT / 'HoneyObs.app'; EXE = APP / 'Contents/MacOS/HoneyObs'; HELPER = APP / 'Contents/Helpers/HoneyObsSession'
EXE.parent.mkdir(parents=True); HELPER.parent.mkdir(parents=True)
shutil.copy2(ROOT / 'Info.plist', APP / 'Contents/Info.plist')
source = os.environ.get('SESSION_OWNERSHIP_SOURCE', 'Sources/HoneyObs/SessionOwnership.swift')
for sources, target in [([source, 'tests/MenuSessionFixture.swift'], EXE), ([source, 'Sources/SessionMonitor/Main.swift'], HELPER)]:
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-framework', 'Cocoa', *sources, '-o', str(target)], cwd=ROOT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True, capture_output=True)
register_app(APP)

def read(path):
    try: return json.loads(path.read_text())
    except (OSError, ValueError): return {}

def command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=5)

def alive(pid):
    value = command('/bin/ps', '-p', str(pid), '-o', 'stat=').stdout.strip()
    return bool(value) and not value.startswith('Z')

def wait(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if result := predicate(): return result
        time.sleep(.04)
    raise AssertionError('メニュー検査の待機期限を超えました')

report = {'actualNSMenu': True, 'actualVM': False, 'baselineExpectedFailure': options.expect_menu_failure, 'success': False, 'cases': {}}
for case in ['menu', 'main-freeze']:
    run = OUT / case; run.mkdir(mode=0o700); owner = {}
    with (run / 'launcher.log').open('w') as log:
        args = [str(EXE), '--test-mode', '--run-directory', str(run)]
        if case == 'main-freeze': args.append('--fixture-main-freeze')
        wrapper = subprocess.Popen(args, stdout=log, stderr=log)
        try:
            owner = wait(lambda: read(run / 'owner.json'))
            wait(lambda: read(run / 'tracking-started.json'))
            wrapper.wait(timeout=9)
            modes = read(run / 'tracking-modes.json')
            if case == 'menu':
                assert modes.get('NSEventTrackingRunLoopMode', 0) >= 20, modes
                if options.expect_menu_failure:
                    assert wrapper.returncode == 1 and not (run / 'tracking-finished.json').exists()
                else:
                    assert wrapper.returncode == 0, read(run / 'session-result.json')
                    assert read(run / 'tracking-finished.json').get('returned')
                    assert read(run / 'finish-result.json').get('acknowledged')
            else:
                assert wrapper.returncode == 1, 'main停止を失効させませんでした'
            assert all(not alive(owner[key]) for key in ['ownerPID', 'clientPID'])
            assert all(command('/bin/launchctl', 'print', owner[key]).returncode == 113 for key in ['ownerService', 'clientService'])
            assert not Path(owner['socketDirectory']).exists()
            report['cases'][case] = {'exit': wrapper.returncode, 'trackingModes': modes, 'allGoneBeforeCleanup': True,
                                     'sessionResult': read(run / 'session-result.json')}
        except BaseException as error:
            report['cases'][case] = {'failed': repr(error), 'owner': owner, 'trackingModes': read(run / 'tracking-modes.json')}
            raise
        finally:
            (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
            for key in ['clientService', 'ownerService']:
                if key in owner: command('/bin/launchctl', 'bootout', owner[key])
            if wrapper.poll() is None: wrapper.terminate(); wrapper.wait(timeout=10)
try:
    require_cleanup()
except BaseException as error:
    report['registryCleanupError'] = str(error)
    (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    raise
report['success'] = True
(OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
for case in report['cases']: print(case + ': PASS', flush=True)
print('実メニュー追跡とmain停止の区別: PASS', OUT)
