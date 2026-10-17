#!/usr/bin/env python3
"""GUI資産と、通信せず検索できる国別IP範囲をアプリへ同梱する。"""
import csv
import gzip
import hashlib
import ipaddress
from pathlib import Path
from build_paths import build_app
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.cache'
RES = build_app(ROOT) / 'Contents/Resources'
NAME = 'dbip-country-lite-2026-10.csv.gz'
SHA256 = '097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80'


def prepare_geo():
    source = CACHE / NAME
    if not source.exists():
        temp = source.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '120',
                        'https://download.db-ip.com/free/' + NAME, '-o', str(temp)], check=True)
        temp.replace(source)
    if hashlib.sha256(source.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('GeoIPのチェックサムが一致しません')
    # ネットワークバイト順の開始IP・終了IP・国コード。IPv4は10、IPv6は34バイト。
    outputs = {4: bytearray(), 6: bytearray()}
    ends = {4: -1, 6: -1}
    with gzip.open(source, 'rt', encoding='utf-8', newline='') as stream:
        for start, end, country in csv.reader(stream):
            first, last = ipaddress.ip_address(start), ipaddress.ip_address(end)
            assert first.version == last.version and int(first) <= int(last)
            assert int(first) > ends[first.version] and len(country) == 2 and country.isascii() and country.isupper()
            outputs[first.version].extend(first.packed + last.packed + country.encode('ascii'))
            ends[first.version] = int(last)
    for version, data in outputs.items():
        (RES / f'geo-v{version}.bin').write_bytes(data)


def main():
    CACHE.mkdir(exist_ok=True)
    RES.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'Resources/Dashboard', RES / 'Dashboard', dirs_exist_ok=True)
    prepare_geo()
    # 採用画像を標準のicnsサイズへ変換する。形や色は変更しない。
    iconset = CACHE / 'AppIcon.iconset'
    iconset.mkdir(exist_ok=True)
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            suffix = '@2x' if scale == 2 else ''
            subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                            str(ROOT / 'Resources/Brand/AppIcon.png'), '--out',
                            str(iconset / f'icon_{size}x{size}{suffix}.png')], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(RES / 'AppIcon.icns')], check=True)
    print('GUI・オフラインGeoIP・採用アイコンの同梱完了')


if __name__ == '__main__':
    main()
