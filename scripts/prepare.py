#!/usr/bin/env python3
"""ビルド時だけ必要な依存取得と、最小initramfsの生成。利用者側では実行しない。"""
import gzip
import hashlib
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.cache'
RES = ROOT / 'build/HoneyObs.app/Contents/Resources'
DEPENDENCIES = [
    ('linux-virt.apk', 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/linux-virt-6.18.56-r0.apk',
     'e3839bfd751ff0a4421484f712b9b29efb514024523736a0ef62521521571b12'),
]


def cpio(files):
    out = io.BytesIO()
    for ino, (name, mode, data) in enumerate(files + [('TRAILER!!!', 0, b'')], 1):
        name = name.encode() + b'\0'
        fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0]
        out.write(b'070701' + ''.join(f'{n:08x}' for n in fields).encode())
        out.write(name)
        out.write(b'\0' * (-out.tell() % 4))
        out.write(data)
        out.write(b'\0' * (-out.tell() % 4))
    return gzip.compress(out.getvalue(), mtime=0)


def main():
    CACHE.mkdir(exist_ok=True)
    RES.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'third_party', RES / 'Licenses', dirs_exist_ok=True)
    for name, url, digest in DEPENDENCIES:
        path = CACHE / name
        if not path.exists():
            print('取得:', name, flush=True)
            with urllib.request.urlopen(url, timeout=60) as source, path.open('wb') as dest:
                shutil.copyfileobj(source, dest)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'チェックサム不一致: {name}')
    env = dict(os.environ, GOOS='linux', GOARCH='arm64', CGO_ENABLED='0')
    subprocess.run(['go', 'build', '-trimpath', '-ldflags=-s -w', '-o', str(CACHE / 'guest-init'), '.'],
                   cwd=ROOT / 'guest', env=env, check=True)
    with tarfile.open(CACHE / 'linux-virt.apk', 'r:gz', ignore_zeros=True) as archive:
        kernel = archive.extractfile('boot/vmlinuz-virt').read()
        # AlpineのEFI用圧縮イメージから、VZLinuxBootLoader用のARM64 Imageを取り出す。
        if kernel[56:60] != b'ARM\x64':
            offset = kernel.find(b'\x1f\x8b\x08')
            if offset < 0:
                raise RuntimeError('未対応のカーネル圧縮形式')
            kernel = zlib.decompress(kernel[offset:], 31)
        if kernel[56:60] != b'ARM\x64':
            raise RuntimeError('ARM64 Linux Imageではありません')
        RES.joinpath('vmlinuz').write_bytes(kernel)
        depname = next(n for n in archive.getnames() if n.endswith('/modules.dep'))
        prefix = depname.removesuffix('modules.dep')
        deps = dict(line.split(':', 1) for line in archive.extractfile(depname).read().decode().splitlines())
        order = []

        def visit(name):
            for dep in deps[name].split():
                visit(dep)
            if name not in order:
                order.append(name)

        visit(next(n for n in deps if n.endswith('/vmw_vsock_virtio_transport.ko.gz')))
        files = [(d, stat.S_IFDIR | 0o755, b'') for d in ['proc', 'sys', 'dev', 'tmp', 'modules']]
        files.append(('init', stat.S_IFREG | 0o555, (CACHE / 'guest-init').read_bytes()))
        for name in order:
            files.append(('modules/' + Path(name).name.removesuffix('.gz'), stat.S_IFREG | 0o444,
                          gzip.decompress(archive.extractfile(prefix + name).read())))
        files.append(('modules/order', stat.S_IFREG | 0o444,
                      '\n'.join(Path(n).name.removesuffix('.gz') for n in order).encode()))
        RES.joinpath('initramfs.gz').write_bytes(cpio(files))
        print('VMモジュール:', ', '.join(Path(n).name for n in order))
    RES.joinpath('cloudflared').unlink(missing_ok=True)
    print('おとりVMの同梱準備完了')


if __name__ == '__main__':
    main()
