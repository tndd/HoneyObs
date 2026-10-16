"""起動した私有HoneyObs.appだけを、試験終了後にLaunch Servicesから解除する。"""
import atexit
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
_registered = set()


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
    return resolved


def _owned_app(app):
    resolved = _owned_location(app)
    if not resolved.is_dir():
        raise ValueError('QAアプリがありません: ' + str(resolved))
    info = plistlib.loads((resolved / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.honeyobs.spike' or info.get('CFBundleExecutable') != 'HoneyObs':
        raise ValueError('HoneyObsのQAバンドルではありません: ' + str(resolved))
    return resolved


def register_app(app):
    """Popen直前に呼ぶ。ここではOS登録を変更せず、終了時の対象だけ記録する。"""
    _registered.add(_owned_app(app))


def unregister_app(app):
    try:
        target = _owned_app(app)  # 終了までにsymlinkへ置き換わった場合も拒否する。
        result = subprocess.run([LSREGISTER, '-u', str(target)], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or 'lsregister exit ' + str(result.returncode))
        return True
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('QAアプリの登録解除に失敗: ' + str(error), file=sys.stderr)
        return False


def cleanup():
    success = True
    for app in sorted(_registered):
        if unregister_app(app):
            _registered.remove(app)
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
