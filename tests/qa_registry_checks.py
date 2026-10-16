#!/usr/bin/env python3
"""Launch Servicesは変更せず、解除対象の所有範囲と呼出位置を検査する。"""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import qa_registry


class QARegistryChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve() / 'repo'
        self.root.mkdir()
        self.root_patch = patch.object(qa_registry, 'ROOT', self.root)
        self.root_patch.start(); self.addCleanup(self.root_patch.stop)
        qa_registry._registered.clear()
        self.addCleanup(qa_registry._registered.clear)
        self.run_patch = patch.object(qa_registry.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', ''))
        self.run = self.run_patch.start(); self.addCleanup(self.run_patch.stop)

    def app(self, path):
        contents = path / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.honeyobs.spike', 'CFBundleExecutable':'HoneyObs'}))
        return path

    def test_only_recorded_apps_after_witness_and_deduplicate(self):
        build = self.app(self.root / 'build/HoneyObs.app')
        private = self.app(self.root / 'test-results/case/private/HoneyObs.app')
        self.app(self.root / 'test-results/unrelated/HoneyObs.app')
        for app in [build, private, build]:
            qa_registry.register_app(app)
        self.run.assert_not_called()  # 稼働・回収の判定中は登録DBへ触れない。
        self.assertTrue(qa_registry.cleanup())
        self.assertEqual({tuple(call.args[0]) for call in self.run.call_args_list},
                         {(qa_registry.LSREGISTER, '-u', str(build)), (qa_registry.LSREGISTER, '-u', str(private))})
        for call in self.run.call_args_list:
            self.assertEqual(call.kwargs['timeout'], 5)
        self.assertTrue(qa_registry.cleanup())
        self.assertEqual(self.run.call_count, 2)

    def test_installed_other_worktree_other_app_and_symlink_refused(self):
        outside = self.app(Path(self.directory.name).resolve() / 'other-worktree/build/HoneyObs.app')
        installed = self.app(Path(self.directory.name).resolve() / 'home/Applications/HoneyObs.app')
        other_app = self.app(self.root / 'build/Other.app')
        link = self.root / 'test-results/HoneyObs.app'
        link.parent.mkdir(parents=True); link.symlink_to(outside, target_is_directory=True)
        for app in [outside, installed, other_app, link, Path('build/HoneyObs.app')]:
            with self.subTest(app=app), self.assertRaises(ValueError):
                qa_registry.register_app(app)
        with patch.object(Path, 'home', return_value=installed.parent.parent), self.assertRaisesRegex(ValueError, '導入済み'):
            qa_registry.register_app(installed)
        self.run.assert_not_called()

    def test_late_symlink_swap_cannot_unregister_another_app(self):
        app = self.app(self.root / 'build/HoneyObs.app')
        qa_registry.register_app(app)
        app.rename(app.with_name('retained.app'))
        outside = self.app(Path(self.directory.name).resolve() / 'outside/HoneyObs.app')
        app.symlink_to(outside, target_is_directory=True)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(qa_registry.cleanup())
        self.run.assert_not_called()

    def test_unregister_failure_is_visible_and_bounded(self):
        app = self.app(self.root / 'build/HoneyObs.app')
        self.run.side_effect = subprocess.TimeoutExpired([], 5)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertFalse(qa_registry.unregister_app(app))
        self.assertIn('登録解除に失敗', output.getvalue())

    def test_only_failed_target_is_retained_for_exit_fallback(self):
        build = self.app(self.root / 'build/HoneyObs.app')
        private = self.app(self.root / 'test-results/private/HoneyObs.app')
        for app in [build, private]:
            qa_registry.register_app(app)
        self.run.side_effect = [subprocess.CompletedProcess([], 0, '', ''),
                                subprocess.CompletedProcess([], 7, '', 'fixture failure'),
                                subprocess.CompletedProcess([], 0, '', '')]
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            qa_registry.require_cleanup()
        self.assertEqual(qa_registry._registered, {private})
        self.assertTrue(qa_registry.cleanup())
        self.assertEqual([call.args[0][-1] for call in self.run.call_args_list], [str(build), str(private), str(private)])

    def test_gate_missing_build_does_not_scan_and_missing_outside_is_refused(self):
        self.assertEqual(qa_registry.main([str(self.root / 'build/HoneyObs.app')]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(qa_registry.main([str(self.root.parent / 'other/build/HoneyObs.app')]), 1)
        self.run.assert_not_called()


class QARegistryOutcomeChecks(unittest.TestCase):
    def run_integration(self, mode):
        directory = tempfile.TemporaryDirectory(prefix='HoneyObs-registry-outcome-')
        self.addCleanup(directory.cleanup)
        root = Path(directory.name).resolve() / 'repo'
        app = root / 'build/HoneyObs.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier':'local.honeyobs.spike', 'CFBundleExecutable':'HoneyObs'}))
        fake = root / 'fixture-lsregister'
        fake.write_text('#!' + sys.executable + '\n' + '''
import json, pathlib, sys
root = pathlib.Path(__file__).parent
assert (root / 'resources-cleaned').read_text() == 'done'
assert sys.argv[1:] == ['-u', str(root / 'build/HoneyObs.app')]
calls = root / 'registry-calls.jsonl'
with calls.open('a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
count = len(calls.read_text().splitlines())
report = root / 'test-results/integration/report.json'
if count == 1:
    assert not report.exists(), 'success/failure report was written before explicit cleanup'
elif report.exists():
    assert 'failure' in json.loads(report.read_text()), 'fallback observed a success report'
mode = (root / 'mode').read_text()
if mode == 'failure' or (mode == 'failure-once' and count == 1):
    print('fixture registration failure', file=sys.stderr)
    raise SystemExit(7)
''')
        fake.chmod(0o755)
        (root / 'mode').write_text(mode)
        script = '''
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import qa_registry, integration
root = pathlib.Path(sys.argv[2])
qa_registry.ROOT = root
qa_registry.LSREGISTER = str(root / 'fixture-lsregister')
integration.OUT = root / 'test-results/integration'
def local_test():
    qa_registry.register_app(root / 'build/HoneyObs.app')
    try:
        return {'matched': True}
    finally:
        (root / 'resources-cleaned').write_text('done')
integration.local_test = local_test
sys.argv = ['integration.py', '--local']
integration.main()
'''
        result = subprocess.run([sys.executable, '-c', script, str(qa_registry.ROOT / 'tests'), str(root)],
                                capture_output=True, text=True, timeout=10)
        report = json.loads((root / 'test-results/integration/report.json').read_text())
        calls = [json.loads(line) for line in (root / 'registry-calls.jsonl').read_text().splitlines()]
        return result, report, calls

    def test_explicit_unregister_failure_cannot_pass_gate_or_report_success(self):
        result, report, calls = self.run_integration('failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PASS', result.stdout)
        self.assertIn('QAアプリの登録解除を確認できません', report['failure'])
        self.assertEqual(len(calls), 2)  # 明示失敗と、終了時だけのfallback。

    def test_fallback_success_does_not_reverse_explicit_failure(self):
        result, report, calls = self.run_integration('failure-once')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PASS', result.stdout)
        self.assertIn('failure', report)
        self.assertEqual(len(calls), 2)

    def test_success_unregisters_once_before_success_report_and_output(self):
        result, report, calls = self.run_integration('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertIn('PASS', result.stdout)
        self.assertNotIn('failure', report)
        self.assertEqual(len(calls), 1)  # 明示成功後のatexitでは再実行しない。


if __name__ == '__main__':
    unittest.main()
