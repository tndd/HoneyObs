#!/usr/bin/env python3
"""Launch Servicesは変更せず、解除対象の所有範囲と呼出位置を検査する。"""
import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
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

    def test_gate_missing_build_does_not_scan_and_missing_outside_is_refused(self):
        self.assertEqual(qa_registry.main([str(self.root / 'build/HoneyObs.app')]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(qa_registry.main([str(self.root.parent / 'other/build/HoneyObs.app')]), 1)
        self.run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
