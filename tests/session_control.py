#!/usr/bin/env python3
"""制御CLIの期限・出力量・FD/PGID継承・OS回収競合を実子で検査する。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test-results' / ('session-control-' + time.strftime('%Y%m%d-%H%M%S'))
OUT.mkdir(parents=True, mode=0o700)
RUNNER, CHILD = OUT / 'runner', OUT / 'child'
SOURCE = OUT / 'child.c'
SOURCE.write_text(r'''#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <fcntl.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  FILE *file=fopen(argv[2],"w"); if(!file)return 3;
  fprintf(file,"{\"pid\":%d,\"pgid\":%d}",getpid(),getpgrp()); fclose(file);
  if(fcntl(atoi(argv[3]),F_GETFD)>=0)return 5;
  if(!strcmp(argv[1],"stop")){ raise(SIGSTOP); for(;;)pause(); }
  if(!strcmp(argv[1],"flood")){ char bytes[4096];memset(bytes,'x',sizeof(bytes));for(int i=0;i<200;i++)write(1,bytes,sizeof(bytes)); }
  if(!strcmp(argv[1],"normal")){ puts("ok");return 7; }
  return 0;
}
''')
subprocess.run(['cc', str(SOURCE), '-o', str(CHILD)], check=True)
subprocess.run(['swiftc', '-D', 'SESSION_CONTROL_TESTING', '-parse-as-library', '-swift-version', '5',
                'Sources/HoneyObs/SessionOwnership.swift', 'tests/SessionControlFixture.swift', '-o', str(RUNNER)], cwd=ROOT, check=True)
for binary in [RUNNER, CHILD]:
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def alive(pid):
    value = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], text=True, capture_output=True).stdout.strip()
    return bool(value) and not value.startswith('Z')


def wait(predicate, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if value := predicate():
            return value
        time.sleep(.025)
    raise AssertionError('制御CLI検証の待機期限を超えました')


report = {}
for mode in ['normal', 'fast', 'flood', 'stop']:
    pidfile, result = OUT / (mode + '-pid.json'), OUT / (mode + '-result.json')
    parent = subprocess.Popen([str(RUNNER), str(CHILD), mode, str(pidfile), str(result)])
    parent.wait(timeout=4)
    assert parent.returncode == 0, parent.returncode
    value, child = read(result), read(pidfile)
    assert child and value and not alive(child['pid']), (mode, child, value)
    assert child['pgid'] == value['pgid'], (child, value)
    assert value['elapsed'] < 2.7 and value['outputBytes'] < 65_800, value
    if mode == 'normal':
        assert value['status'] == 7 and value['prefix'] == 'ok\n', value
    elif mode == 'fast':
        assert value['status'] == 0, value
    else:
        assert value['status'] == -1 and 'reap済み' in value['prefix'], value
        assert ('期限超過' if mode == 'stop' else '出力上限') in value['prefix'], value
    report[mode] = dict(value, childGoneBeforeCleanup=True, sameProcessGroup=True)
    print(mode + ': PASS', flush=True)

# 親ジョブbootoutと、SIGSTOPした制御CLIの回収が競合しても孤児を残さない。
import plistlib
label = 'local.honeyobs.control-test.' + str(uuid.uuid4())
service = 'gui/' + str(os.getuid()) + '/' + label
pidfile, result = OUT / 'race-pid.json', OUT / 'race-result.json'
plist = OUT / 'race.plist'
plist.write_bytes(plistlib.dumps({'Label': label, 'ProgramArguments': [str(RUNNER), str(CHILD), 'stop', str(pidfile), str(result)],
                                 'RunAtLoad': True, 'KeepAlive': False, 'AbandonProcessGroup': False, 'ExitTimeOut': 1}))
child = {}
try:
    subprocess.run(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)], check=True)
    child = wait(lambda: read(pidfile))
    job = subprocess.check_output(['/bin/launchctl', 'print', service], text=True)
    parent_pid = int(next(line.split('=')[1] for line in job.splitlines() if line.strip().startswith('pid = ')))
    assert child['pgid'] == parent_pid, (child, parent_pid)
    start = time.monotonic()
    subprocess.run(['/bin/launchctl', 'bootout', service], check=True)
    wait(lambda: not alive(parent_pid) and not alive(child['pid']), 4)
    assert subprocess.run(['/bin/launchctl', 'print', service], capture_output=True).returncode == 113
    report['os-bootout-race'] = {'parentGone': True, 'stoppedControlChildGone': True, 'allGoneWithin': round(time.monotonic() - start, 3), 'beforeTestCleanup': True}
    print('os-bootout-race: PASS', flush=True)
finally:
    subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)
    if child and alive(child['pid']):
        current = subprocess.check_output(['ps', '-p', str(child['pid']), '-o', 'command='], text=True).strip()
        if current.startswith(str(CHILD) + ' '):
            os.kill(child['pid'], signal.SIGKILL)
(OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print('制御CLIの境界: PASS', OUT)
