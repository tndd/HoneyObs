#!/usr/bin/env python3
"""製品のLinux権限処理をNIC/共有/ディスクなしの私有VMで検証する。"""
import os
import platform
from pathlib import Path
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import prepare

def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('この検査にはApple Siliconの実Macが必要です。')
    directory = ROOT / 'test-results' / ('egress-privileges-' + str(os.getpid()))
    directory.mkdir(parents=True, mode=0o700)
    binary = directory / 'guest-tests'
    subprocess.run(['go', 'test', '-c', '-o', str(binary), '.'], cwd=ROOT / 'egress',
                   env=dict(os.environ, GOOS='linux', GOARCH='arm64', CGO_ENABLED='0'), check=True)
    ramdisk = directory / 'initramfs.gz'
    ramdisk.write_bytes(prepare.cpio([('proc', stat.S_IFDIR | 0o555, b''),
                                     ('dev', stat.S_IFDIR | 0o555, b''),
                                     ('init', stat.S_IFREG | 0o555, binary.read_bytes())]))
    runner = directory / 'runner'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-framework', 'Virtualization',
                    str(ROOT / 'tests/EgressPrivileges.swift'), '-o', str(runner)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'entitlements.plist'), str(runner)], check=True)
    kernel = ROOT / 'build/Applications.noindex/HoneyObs.app/Contents/Resources/vmlinuz'
    subprocess.run([str(runner), str(kernel), str(ramdisk), str(directory / 'console.log')], check=True, timeout=40)

if __name__ == '__main__':
    main()
