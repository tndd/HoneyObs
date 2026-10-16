#!/usr/bin/env python3
"""VMを起動せず、ブランド資産・同梱物・開発署名を検査する。

--distributionは追加でDeveloper ID、公証staple、Gatekeeper判定を要求する。
対応ソースの提供と実配布先の起動は別ゲートであり、この検査だけでは完了しない。
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def command(*arguments):
    return subprocess.run(arguments, capture_output=True, timeout=60)


def check(app, distribution=False):
    contents = app / 'Contents'
    resources = contents / 'Resources'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    expected = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    for key in ['CFBundleIdentifier', 'CFBundleName', 'CFBundleExecutable', 'CFBundleIconFile', 'CFBundleVersion']:
        if info.get(key) != expected[key]:
            raise ValueError('アプリ情報が製品の設定と一致しません: ' + key)
    icon = (resources / 'AppIcon.icns').read_bytes()
    if len(icon) < 10000 or icon[:4] != b'icns' or int.from_bytes(icon[4:8], 'big') != len(icon):
        raise ValueError('採用アイコンのicnsが欠損しています')
    for path in [contents / 'MacOS/HoneyObs', *[resources / name for name in
                 ['vmlinuz', 'initramfs.gz', 'cloudflared', 'geo-v4.bin', 'geo-v6.bin']]]:
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError('同梱実行資産が欠損しています: ' + str(path))
    for source, destination in [('Resources/Dashboard', resources / 'Dashboard'), ('third_party', resources / 'Licenses')]:
        for original in (ROOT / source).iterdir():
            if original.is_file() and original.read_bytes() != (destination / original.name).read_bytes():
                raise ValueError('同梱資産が製品の設定と一致しません: ' + original.name)
    for name, width in [('geo-v4.bin', 10), ('geo-v6.bin', 34)]:
        if (resources / name).stat().st_size % width:
            raise ValueError('GeoIPの固定長レコードが不正です: ' + name)
    verified = command('codesign', '--verify', '--deep', '--strict', str(app))
    if verified.returncode:
        raise ValueError('同梱物を含むコード署名の検証に失敗しました')
    entitlement = command('codesign', '-d', '--entitlements', ':-', str(app))
    if entitlement.returncode or plistlib.loads(entitlement.stdout).get('com.apple.security.virtualization') is not True:
        raise ValueError('Virtualization entitlementがありません')
    identity = command('codesign', '-dvvv', str(app)).stderr.decode('utf-8', errors='replace')
    developer_id = 'Authority=Developer ID Application:' in identity and 'TeamIdentifier=not set' not in identity
    blockers = []
    if not developer_id:
        blockers.append('Developer ID Application署名がありません（開発署名は一般配布の証明ではありません）')
    if distribution and developer_id:
        for arguments, label in [(['xcrun', 'stapler', 'validate', str(app)], '公証staple'),
                                 (['spctl', '--assess', '--type', 'execute', str(app)], 'Gatekeeper')]:
            if command(*arguments).returncode:
                blockers.append(label + 'の検証が成功していません')
    return {'bundle': str(app), 'baseline': 'PASS', 'developerID': developer_id,
            'distributionSigning': 'BLOCKED' if blockers else ('PASS' if distribution else 'UNVERIFIED'),
            'blockers': blockers, 'separateGates': ['GPL対応ソースの提供', '実配布先での起動']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', type=Path, default=ROOT / 'build/HoneyObs.app')
    parser.add_argument('--distribution', action='store_true')
    args = parser.parse_args()
    try:
        result = check(args.app.resolve(), args.distribution)
    except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print('バンドル検査失敗: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if args.distribution and result['blockers'] else 0


if __name__ == '__main__':
    sys.exit(main())
