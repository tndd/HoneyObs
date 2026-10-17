"""起動した私有HoneyObs.appだけを、試験終了後にLaunch Servicesから解除する。"""
import atexit
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
_registered = {}


def _owned_location(app):
    original = Path(app)
    if not original.is_absolute():
        raise ValueError('QAアプリには絶対パスが必要です')
    resolved = original.resolve()
    if resolved != original or resolved.name != 'HoneyObs.app':
        raise ValueError('symlinkや別アプリの登録は解除しません: ' + str(original))
    installed = (Path.home() / 'Applications').resolve()
    if installed == resolved or installed in resolved.parents:
        raise ValueError('導入済みアプリの登録は解除しません: ' + str(resolved))
    if not any(base in resolved.parents for base in [ROOT / 'build', ROOT / 'test-results']):
        raise ValueError('この作業treeのQAアプリだけを指定してください: ' + str(resolved))
    if resolved.parent.name != 'Applications.noindex':
        raise ValueError('生成アプリはApplications.noindex直下へ置いてください: ' + str(resolved))
    return resolved


def generated_app_path(directory):
    """コピー前に保存先を検査し、索引対象外の専用バンドルパスだけを返す。"""
    return _owned_location(Path(directory) / 'Applications.noindex/HoneyObs.app')


def _owned_app(app, expected_identifier=None):
    resolved = _owned_location(app)
    if not resolved.is_dir():
        raise ValueError('QAアプリがありません: ' + str(resolved))
    info = plistlib.loads((resolved / 'Contents/Info.plist').read_bytes())
    identifier = info.get('CFBundleIdentifier')
    if identifier not in {'local.honeyobs.spike', 'local.honeyobs.session-jobs-fixture'} or info.get('CFBundleExecutable') != 'HoneyObs':
        raise ValueError('HoneyObsのQAバンドルではありません: ' + str(resolved))
    if expected_identifier is not None and identifier != expected_identifier:
        raise ValueError('登録時と異なるQAバンドルの登録は解除しません: ' + str(resolved))
    return resolved, identifier


def register_app(app):
    """Popen直前に呼ぶ。ここではOS登録を変更せず、終了時の対象だけ記録する。"""
    target, identifier = _owned_app(app, _registered.get(Path(app)))
    _registered[target] = identifier


def _registration_absent(target, identifier):
    # noindexの非GUI fixtureは一度も登録されない。CLIのnot-foundだけでは成功にしない。
    result = subprocess.run(['swift', str(Path(__file__).with_name('RegisteredApplications.swift')),
                             identifier, str(target)], capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise RuntimeError('Launch Servicesの登録有無を確認できません')
    value = json.loads(result.stdout)
    return (isinstance(value, dict) and set(value) == {'identifier', 'path', 'absent'}
            and value['identifier'] == identifier and value['path'] == str(target) and value['absent'] is True)


def unregister_app(app):
    try:
        target, identifier = _owned_app(app, _registered.get(Path(app)))  # 終了までのpath/ID差替えも拒否する。
        result = subprocess.run([LSREGISTER, '-u', str(target)], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            if '-10814' not in result.stderr or not _registration_absent(target, identifier):
                raise RuntimeError(result.stderr.strip() or 'lsregister exit ' + str(result.returncode))
            _owned_app(target, identifier)  # 照会中にpath/IDが差し替わっていないことも確認する。
        return True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('QAアプリの登録解除に失敗: ' + str(error), file=sys.stderr)
        return False


def cleanup():
    success = True
    for app in sorted(_registered):
        if unregister_app(app):
            del _registered[app]
        else:
            success = False
    return success


def require_cleanup():
    """成功記録の前に呼ぶ。失敗対象はatexitの再試行用に残す。"""
    if not cleanup():
        raise RuntimeError('QAアプリの登録解除を確認できません: ' + ', '.join(map(str, sorted(_registered))))


atexit.register(cleanup)


def main(arguments):
    if len(arguments) != 1:
        print('usage: qa_registry.py /absolute/path/to/own/HoneyObs.app', file=sys.stderr)
        return 1
    try:
        target = _owned_location(arguments[0])
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    # buildが完成しなかったgateのEXITでも、探索せず指定先だけを扱う。
    if not target.exists() and not target.is_symlink():
        return 0
    return 0 if unregister_app(target) else 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
