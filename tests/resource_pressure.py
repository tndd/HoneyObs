"""実CPU負荷・実常駐メモリを測定する試験用controller。OS設定は変更しない。"""
import json
from pathlib import Path
import re
import subprocess
import threading
import time


def command(*args):
    return subprocess.check_output(args, text=True, timeout=5)


def memory_state():
    free = re.search(r'free percentage: (\d+)%', command('/usr/bin/memory_pressure', '-Q'))
    swap = re.search(r'used = ([\d.]+)M', command('/usr/sbin/sysctl', 'vm.swapusage'))
    if not free or not swap:
        raise RuntimeError('メモリの余力を測定できません')
    return {'freePercent': int(free[1]), 'swapMiB': float(swap[1]),
            'level': int(command('/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'))}


def over_budget(value, swap_baseline):
    return value['level'] not in (1, 2) or value['freePercent'] < 12 or value['swapMiB'] - swap_baseline > 512


class ResourcePressure:
    suite_swap_start = None

    def __init__(self, run, profile):
        self.run, self.profile = run, profile
        self.workers, self.files, self.samples = [], [], []
        self.done = threading.Event()
        self.guard = None
        self.failure = None
        self.stopped = False
        self.before = memory_state()
        if ResourcePressure.suite_swap_start is None:
            ResourcePressure.suite_swap_start = self.before['swapMiB']
        self.swap_baseline = min(self.before['swapMiB'], ResourcePressure.suite_swap_start)
        self.cpu_count = int(command('/usr/sbin/sysctl', '-n', 'hw.logicalcpu')) if profile in ('cpu', 'combined') else 0
        physical = int(command('/usr/sbin/sysctl', '-n', 'hw.memsize'))
        self.memory_mib = min(8192, physical // (4 * 1024**2)) if profile in ('memory', 'combined') else 0
        self.actual_memory_mib = 0
        self.started = time.monotonic()

    def start(self):
        assert self.before['level'] == 1 and self.before['freePercent'] >= 50, self.before
        binary = Path(__file__).resolve().parent.parent / 'test-results/pressure-worker'
        assert binary.is_file(), 'clang -O2 tests/pressure_worker.c -o test-results/pressure-worker を先に実行してください'
        self.guard = threading.Thread(target=self.sample, daemon=True)
        self.guard.start()
        # CPU負荷を先に成立させ、メモリwarning直後に故障を注入できるよう最後に割り当てる。
        allocations = [0] * self.cpu_count + ([self.memory_mib] if self.memory_mib else [])
        for index, mib in enumerate(allocations):
            log = (self.run / f'pressure-worker-{index}.jsonl').open('w')
            self.files.append(log)
            worker = subprocess.Popen([str(binary), str(mib)], stdout=log, stderr=subprocess.STDOUT)
            self.workers.append(worker)
            end = time.monotonic() + 25
            while time.monotonic() < end:
                self.check()
                if '"ready":true' in (self.run / f'pressure-worker-{index}.jsonl').read_text():
                    ready = json.loads((self.run / f'pressure-worker-{index}.jsonl').read_text().splitlines()[0])
                    self.actual_memory_mib += ready['allocatedBytes'] / 1024**2
                    break
                time.sleep(.1)
            else:
                raise AssertionError('資源負荷の準備期限を超えました')
            if self.cpu_count and index == self.cpu_count - 1:
                time.sleep(3)
                self.top = command('/usr/bin/top', '-l', '2', '-s', '1', '-n', '0')
                (self.run / 'pressure-top.txt').write_text(self.top)
                idle = [float(v) for v in re.findall(r'([\d.]+)% idle', self.top)]
                assert idle and idle[-1] < 20, idle
        self.check()
        if self.memory_mib:
            assert self.actual_memory_mib >= 512

    def mark_fault(self):
        self.at_fault = memory_state()
        self.at_fault['at'] = time.monotonic()
        self.check()

    def check(self):
        assert not self.failure, self.failure
        assert all(worker.poll() is None for worker in self.workers), '判定前に負荷workerが終了しました'

    def sample(self):
        while not self.done.is_set():
            try:
                value = memory_state()
                value['at'] = time.monotonic()
                pids = [str(worker.pid) for worker in self.workers if worker.poll() is None]
                value['rssMiB'] = 0
                if pids:
                    rss = command('/bin/ps', '-p', ','.join(pids), '-o', 'rss=')
                    value['rssMiB'] = sum(int(line) for line in rss.split()) / 1024
                self.samples.append(value)
                (self.run / 'pressure-samples.json').write_text(json.dumps(self.samples, indent=2))
                if over_budget(value, self.swap_baseline):
                    raise RuntimeError('critical/余力12%未満/swap増分512MiB超過の中止条件に達しました')
            except Exception as error:
                self.failure = repr(error)
                for worker in self.workers:
                    if worker.poll() is None:
                        worker.terminate()
                return
            self.done.wait(.5)

    def stop(self):
        if self.stopped:
            return
        self.done.set()
        if self.guard:
            self.guard.join(timeout=8)
        for worker in self.workers:
            if worker.poll() is None:
                worker.terminate()
            try:
                worker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                worker.kill(); worker.wait(timeout=3)
        for log in self.files:
            log.close()
        self.stopped = True

    def report(self):
        utilization = []
        for index in range(len(self.workers)):
            rows = [json.loads(line) for line in (self.run / f'pressure-worker-{index}.jsonl').read_text().splitlines()]
            ticks = [row for row in rows if 'cpu' in row]
            if len(ticks) >= 2:
                utilization.append(round(100 * (ticks[-1]['cpu'] - ticks[0]['cpu']) /
                                         (ticks[-1]['wall'] - ticks[0]['wall']), 2))
        return {'profile': self.profile, 'cpuWorkers': self.cpu_count, 'memoryLimitMiB': self.memory_mib,
                'actualTouchedMiB': self.actual_memory_mib,
                'suiteSwapBaselineMiB': self.swap_baseline,
                'atFault': getattr(self, 'at_fault', None),
                'workerCPUPercent': utilization,
                'globalIdlePercentAtReady': [float(v) for v in re.findall(r'([\d.]+)% idle', getattr(self, 'top', ''))][-1:],
                'initial': self.before, 'failure': self.failure, 'workersGone': all(p.poll() is not None for p in self.workers),
                'peakWorkerRSSMiB': max((s['rssMiB'] for s in self.samples), default=0),
                'minimumFreePercent': min((s['freePercent'] for s in self.samples), default=None),
                'pressureLevels': sorted(set(s['level'] for s in self.samples)),
                'swapPeakMiB': max((s['swapMiB'] for s in self.samples), default=0),
                'sampleCount': len(self.samples), 'lastSampleAt': self.samples[-1]['at'] if self.samples else None}
