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
import uuid
from unittest.mock import patch

import qa_registry


class QARegistryChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(suffix='.noindex')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve() / 'repo'
        self.root.mkdir()
        self.root_patch = patch.object(qa_registry, 'ROOT', self.root)
        self.root_patch.start(); self.addCleanup(self.root_patch.stop)
        qa_registry._registered.clear()
        self.addCleanup(qa_registry._registered.clear)
        self.run_patch = patch.object(qa_registry.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', ''))
        self.run = self.run_patch.start(); self.addCleanup(self.run_patch.stop)

    def app(self, path, identifier='local.honeyobs.spike'):
        contents = path / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier, 'CFBundleExecutable':'HoneyObs'}))
        return path

    def test_only_recorded_apps_after_witness_and_deduplicate(self):
        build = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        private = self.app(self.root / 'test-results/case/private/Applications.noindex/HoneyObs.app')
        self.app(self.root / 'test-results/unrelated/Applications.noindex/HoneyObs.app')
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
        outside = self.app(Path(self.directory.name).resolve() / 'other-worktree/build/Applications.noindex/HoneyObs.app')
        installed = self.app(Path(self.directory.name).resolve() / 'home/Applications/HoneyObs.app')
        other_app = self.app(self.root / 'build/Other.app')
        link = self.root / 'test-results/HoneyObs.app'
        link.parent.mkdir(parents=True); link.symlink_to(outside, target_is_directory=True)
        for app in [outside, installed, other_app, link, Path('build/Applications.noindex/HoneyObs.app')]:
            with self.subTest(app=app), self.assertRaises(ValueError):
                qa_registry.register_app(app)
        with patch.object(Path, 'home', return_value=installed.parent.parent), self.assertRaisesRegex(ValueError, '導入済み'):
            qa_registry.register_app(installed)
        self.run.assert_not_called()

    def test_generated_path_is_checked_before_bundle_creation(self):
        run = self.root / 'test-results/new-run'
        app = qa_registry.generated_app_path(run)
        self.assertEqual(app, run / 'Applications.noindex/HoneyObs.app')
        self.assertFalse(run.exists())
        outside = self.root.parent / 'outside'
        for directory in [outside, Path('test-results/relative')]:
            with self.subTest(directory=directory), self.assertRaises(ValueError):
                qa_registry.generated_app_path(directory)
        link = self.root / 'test-results/link'
        link.parent.mkdir(parents=True); link.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            qa_registry.generated_app_path(link)
        self.assertFalse(outside.exists())

    def test_indexable_parent_and_foreign_identifier_are_refused(self):
        ordinary = self.app(self.root / 'test-results/indexable/HoneyObs.app')
        foreign = self.app(self.root / 'test-results/foreign/Applications.noindex/HoneyObs.app', 'local.other.app')
        for app in [ordinary, foreign]:
            with self.subTest(app=app), self.assertRaises(ValueError):
                qa_registry.register_app(app)
        self.run.assert_not_called()

    def test_exact_session_fixture_identifier_is_recorded_and_unregistered(self):
        app = self.app(self.root / 'test-results/jobs/Applications.noindex/HoneyObs.app', 'local.honeyobs.session-jobs-fixture')
        qa_registry.register_app(app)
        qa_registry.require_cleanup()
        self.assertEqual(self.run.call_args.args[0], [qa_registry.LSREGISTER, '-u', str(app)])

    def test_late_cross_identifier_swap_is_refused(self):
        app = self.app(self.root / 'test-results/swap/Applications.noindex/HoneyObs.app')
        qa_registry.register_app(app)
        info = app / 'Contents/Info.plist'
        value = plistlib.loads(info.read_bytes())
        value['CFBundleIdentifier'] = 'local.honeyobs.session-jobs-fixture'
        info.write_bytes(plistlib.dumps(value))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            qa_registry.require_cleanup()
        self.run.assert_not_called()

    def test_late_symlink_swap_cannot_unregister_another_app(self):
        app = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        qa_registry.register_app(app)
        app.rename(app.with_name('retained.app'))
        outside = self.app(Path(self.directory.name).resolve() / 'outside/HoneyObs.app')
        app.symlink_to(outside, target_is_directory=True)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(qa_registry.cleanup())
        self.run.assert_not_called()

    def test_unregister_failure_is_visible_and_bounded(self):
        app = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        self.run.side_effect = subprocess.TimeoutExpired([], 5)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertFalse(qa_registry.unregister_app(app))
        self.assertIn('登録解除に失敗', output.getvalue())

    def test_not_found_requires_independent_absence_confirmation(self):
        app = self.app(self.root / 'test-results/jobs/Applications.noindex/HoneyObs.app', 'local.honeyobs.session-jobs-fixture')
        qa_registry.register_app(app)
        self.run.return_value = subprocess.CompletedProcess([], 1, '', 'failed to scan: -10814 from spotlight')
        with patch.object(qa_registry, '_registration_absent', return_value=True) as presence:
            qa_registry.require_cleanup()
        presence.assert_called_once_with(app, 'local.honeyobs.session-jobs-fixture')
        self.assertEqual(qa_registry._registered, {})

    def test_not_found_with_registration_or_failed_lookup_is_still_failure(self):
        app = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        qa_registry.register_app(app)
        self.run.return_value = subprocess.CompletedProcess([], 1, '', 'failed to scan: -10814')
        for answer in [False, subprocess.TimeoutExpired([], 15)]:
            with self.subTest(answer=answer), patch.object(qa_registry, '_registration_absent', side_effect=answer if isinstance(answer, Exception) else None, return_value=answer), contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(qa_registry.cleanup())
                self.assertIn(app, qa_registry._registered)

    def test_absence_lookup_cannot_hide_late_identifier_swap(self):
        app = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        qa_registry.register_app(app)
        self.run.return_value = subprocess.CompletedProcess([], 1, '', 'failed to scan: -10814')
        def swapped(*_):
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.honeyobs.session-jobs-fixture', 'CFBundleExecutable':'HoneyObs'}))
            return True
        with patch.object(qa_registry, '_registration_absent', side_effect=swapped), contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(qa_registry.cleanup())
        self.assertIn(app, qa_registry._registered)

    def test_only_failed_target_is_retained_for_exit_fallback(self):
        build = self.app(self.root / 'build/Applications.noindex/HoneyObs.app')
        private = self.app(self.root / 'test-results/private/Applications.noindex/HoneyObs.app')
        for app in [build, private]:
            qa_registry.register_app(app)
        self.run.side_effect = [subprocess.CompletedProcess([], 0, '', ''),
                                subprocess.CompletedProcess([], 7, '', 'fixture failure'),
                                subprocess.CompletedProcess([], 0, '', '')]
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
            qa_registry.require_cleanup()
        self.assertEqual(set(qa_registry._registered), {private})
        self.assertTrue(qa_registry.cleanup())
        self.assertEqual([call.args[0][-1] for call in self.run.call_args_list], [str(build), str(private), str(private)])

    def test_gate_missing_build_does_not_scan_and_missing_outside_is_refused(self):
        self.assertEqual(qa_registry.main([str(self.root / 'build/Applications.noindex/HoneyObs.app')]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(qa_registry.main([str(self.root.parent / 'other/build/Applications.noindex/HoneyObs.app')]), 1)
        self.run.assert_not_called()


class RegisteredApplicationsChecks(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'macOSの読み取り専用APIを使う')
    def test_missing_identifier_is_confirmed_by_public_api_without_registering_app(self):
        helper = Path(__file__).with_name('RegisteredApplications.swift')
        identifier = 'local.honeyobs.qa.missing.' + uuid.uuid4().hex
        target = '/tmp/HoneyObs-registry-does-not-exist.app'
        result = subprocess.run(['swift', str(helper), identifier, target], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'identifier':identifier, 'path':target, 'absent':True})


class QARegistryOutcomeChecks(unittest.TestCase):
    def run_integration(self, mode):
        directory = tempfile.TemporaryDirectory(prefix='HoneyObs-registry-outcome-', suffix='.noindex')
        self.addCleanup(directory.cleanup)
        root = Path(directory.name).resolve() / 'repo'
        app = root / 'build/Applications.noindex/HoneyObs.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier':'local.honeyobs.spike', 'CFBundleExecutable':'HoneyObs'}))
        fake = root / 'fixture-lsregister'
        fake.write_text('#!' + sys.executable + '\n' + '''
import json, pathlib, sys
root = pathlib.Path(__file__).parent
assert (root / 'resources-cleaned').read_text() == 'done'
assert sys.argv[1:] == ['-u', str(root / 'build/Applications.noindex/HoneyObs.app')]
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
    qa_registry.register_app(root / 'build/Applications.noindex/HoneyObs.app')
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


class BuildPathChecks(unittest.TestCase):
    def test_all_resource_preparers_share_the_build_bundle_location(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
        import prepare, prepare_egress, prepare_gui
        from build_paths import build_app
        expected = build_app(prepare.ROOT) / 'Contents/Resources'
        self.assertEqual([prepare.RES, prepare_egress.RES, prepare_gui.RES], [expected] * 3)

    def test_build_path_rejects_symlink_ancestors_before_preparing_resources(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
        from build_paths import build_app
        with tempfile.TemporaryDirectory(suffix='.noindex') as directory:
            root = Path(directory).resolve() / 'repo'; root.mkdir()
            self.assertEqual(build_app(root), root / 'build/Applications.noindex/HoneyObs.app')
            self.assertFalse((root / 'build').exists())
            outside = Path(directory).resolve() / 'outside'; outside.mkdir()
            (root / 'build').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                build_app(root)
            self.assertEqual(list(outside.iterdir()), [])
            with self.assertRaises(ValueError):
                build_app(Path('repo'))


class BackgroundSessionPreflightChecks(unittest.TestCase):
    def test_unlocked_console_keeps_existing_ui_gate(self):
        from app_background import session_blocker
        self.assertIsNone(session_blocker({'available':True, 'locked':False, 'onConsole':True}))
        self.assertIsNotNone(session_blocker({'available':False}))
        self.assertIsNotNone(session_blocker({'available':True, 'locked':False, 'onConsole':False}))

    def test_locked_session_records_blocker_without_launch_or_pass(self):
        import app_background
        with tempfile.TemporaryDirectory(suffix='.noindex') as directory:
            output = Path(directory) / 'result'
            report = {'cases':{}}
            stdout = io.StringIO()
            with patch.object(app_background, 'OUT', output), patch.object(app_background, 'REPORT', report), \
                 patch.object(app_background, 'session_state', return_value={'available':True, 'locked':True, 'onConsole':True}), \
                 patch.object(app_background.subprocess, 'Popen') as launch, \
                 patch.object(sys, 'argv', ['app_background.py']), contextlib.redirect_stdout(stdout):
                with self.assertRaises(SystemExit) as caught:
                    app_background.main()
                self.assertIn('BLOCKED', str(caught.exception))
                launch.assert_not_called()
            saved = json.loads((output / 'report.json').read_text())
            self.assertIn('ロック中', saved['blocked'])
            self.assertEqual(saved['cases'], {})
            self.assertNotIn('PASS', stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
