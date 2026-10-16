#!/usr/bin/env python3
"""一時フォルダ内の署名済みfixtureで導入・更新・失敗復旧を検証する。

Launch Services登録だけをfixtureへ置換する。実ユーザーのアプリと登録DBは変更しない。
mvの失敗はPATH内のfixtureで一度だけ注入し、実際のシェルの復旧処理を検査する。
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


class InstallChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix='HoneyObs-install-fixture-')
        cls.binary = Path(cls.shared.name) / 'HoneyObs'
        subprocess.run(['cc', '-x', 'c', '-', '-o', str(cls.binary)],
                       input=b'#include <unistd.h>\nint main(void) { for (;;) pause(); }\n', check=True)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='HoneyObs-install-check-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.destination = self.root / 'Applications [fixture]'
        self.destination.mkdir()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        script = (ROOT / 'scripts/install.sh').read_text()
        self.assertEqual(script.count(LSREGISTER), 1)
        (scripts / 'install.sh').write_text(script.replace(LSREGISTER, 'fixture-lsregister'))
        self.commands = self.root / 'commands'
        self.commands.mkdir()
        self.write_command('fixture-lsregister', '''#!/bin/bash
if [[ "${FIXTURE_FAIL:-}" == register && ! -e "$FIXTURE_MARK" ]]; then
  touch "$FIXTURE_MARK"; exit 1
fi
exit 0
''')
        self.write_command('mv', '''#!/bin/bash
if [[ "${FIXTURE_FAIL:-}" == candidate && "$1" == */.HoneyObs-install.*/HoneyObs.app && ! -e "$FIXTURE_MARK" ]]; then
  touch "$FIXTURE_MARK"; exit 1
fi
if [[ "${FIXTURE_FAIL:-}" == backup && "$1" == */previous.app && "$2" == */.HoneyObs-previous.app && ! -e "$FIXTURE_MARK" ]]; then
  touch "$FIXTURE_MARK"; exit 1
fi
if [[ "${FIXTURE_FAIL:-}" == recovery && ( "$1" == */.HoneyObs-install.*/HoneyObs.app || "$1" == */previous.app ) ]]; then exit 1; fi
exec /bin/mv "$@"
''')
        self.source = self.root / 'build/HoneyObs.app'
        self.target = self.destination / 'HoneyObs.app'
        self.backup = self.destination / '.HoneyObs-previous.app'
        self.make_app(self.source, 'new')

    def write_command(self, name, source):
        path = self.commands / name
        path.write_text(source)
        path.chmod(0o755)

    def make_app(self, path, version):
        (path / 'Contents/MacOS').mkdir(parents=True)
        resources = path / 'Contents/Resources'
        resources.mkdir()
        shutil.copy2(self.binary, path / 'Contents/MacOS/HoneyObs')
        (resources / 'AppIcon.icns').write_bytes(b'fixture-icon')
        (resources / 'version').write_text(version)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.honeyobs.install-fixture',
            'CFBundleName': 'HoneyObs', 'CFBundleExecutable': 'HoneyObs',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': version,
        }))
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def install(self, *, rollback=False, fail='', succeeds=True):
        environment = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ['PATH'],
                           FIXTURE_FAIL=fail, FIXTURE_MARK=str(self.root / 'failed-once'))
        arguments = ['bash', str(self.root / 'scripts/install.sh')]
        if rollback:
            arguments.append('--rollback')
        result = subprocess.run(arguments + [str(self.destination)], env=environment,
                                text=True, errors='replace', capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result

    def version(self, app):
        return (app / 'Contents/Resources/version').read_text()

    def test_first_install(self):
        self.install()
        self.assertEqual(self.version(self.target), 'new')
        self.assertFalse(self.backup.exists())

    def test_update_and_rollback_keep_both_versions(self):
        self.make_app(self.target, 'old')
        self.install()
        self.assertEqual(self.version(self.target), 'new')
        self.assertEqual(self.version(self.backup), 'old')
        self.install(rollback=True)
        self.assertEqual(self.version(self.target), 'old')
        self.assertEqual(self.version(self.backup), 'new')

    def test_failures_restore_current_and_previous(self):
        for failure in ['candidate', 'register', 'backup']:
            with self.subTest(failure=failure):
                self.make_app(self.target, 'old')
                self.make_app(self.backup, 'older')
                self.install(fail=failure, succeeds=False)
                self.assertEqual(self.version(self.target), 'old')
                self.assertEqual(self.version(self.backup), 'older')
                self.assertFalse(list(self.destination.glob('.HoneyObs-install.*')))
                shutil.rmtree(self.target)
                shutil.rmtree(self.backup)
                (self.root / 'failed-once').unlink(missing_ok=True)

    def test_failed_recovery_retains_old_bundle(self):
        self.make_app(self.target, 'old')
        result = self.install(fail='recovery', succeeds=False)
        self.assertIn('旧版を削除せず保持', result.stderr)
        stages = list(self.destination.glob('.HoneyObs-install.*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual(self.version(stages[0] / 'previous.app'), 'old')

    def test_invalid_source_preserves_current(self):
        self.make_app(self.target, 'old')
        (self.source / 'Contents/Resources/version').write_text('tampered')
        self.install(succeeds=False)
        self.assertEqual(self.version(self.target), 'old')

    def test_running_app_is_not_replaced(self):
        self.make_app(self.target, 'old')
        process = subprocess.Popen([str(self.target / 'Contents/MacOS/HoneyObs')])
        try:
            result = self.install(succeeds=False)
            self.assertIn('終了してから', result.stderr)
            self.assertEqual(self.version(self.target), 'old')
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_symlink_is_not_followed(self):
        self.make_app(self.backup, 'old')
        self.target.symlink_to(self.backup)
        self.install(succeeds=False)
        self.assertEqual(self.version(self.backup), 'old')


if __name__ == '__main__':
    unittest.main(verbosity=2)
