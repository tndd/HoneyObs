#!/usr/bin/env python3
"""NICなし通信VM用の固定資産を生成する（ビルド時のみネットワーク使用）。"""
import gzip
import hashlib
import os
from pathlib import Path
from build_paths import build_app
import shutil
import stat
import subprocess
import tarfile
import urllib.request
import prepare

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.cache'
RES = build_app(ROOT) / 'Contents/Resources'
URL = 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-linux-arm64'
SHA256 = 'e6422b9d4f72d3194bc5a38676f13667c06666523217b842a877d72a80b5ac08'


def main():
    CACHE.mkdir(exist_ok=True)
    RES.mkdir(parents=True, exist_ok=True)
    binary = CACHE / 'cloudflared-linux-arm64'
    if not binary.exists():
        print('取得: cloudflared-linux-arm64', flush=True)
        with urllib.request.urlopen(URL, timeout=60) as src, binary.open('wb') as dst:
            shutil.copyfileobj(src, dst)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('cloudflared Linux ARM64のチェックサム不一致')
    kernel = CACHE / 'linux-virt.apk'
    if not kernel.exists() or hashlib.sha256(kernel.read_bytes()).hexdigest() != prepare.DEPENDENCIES[0][2]:
        raise RuntimeError('検証済みkernelがありません。先にscripts/prepare.pyを実行してください')
    # NNPを全Go threadへ同期するAllThreadsSyscallはcgo外部threadを扱えない。
    # CGO_ENABLED=0は通信VM launcherの権限境界の必須ビルド条件。
    subprocess.run(['go', 'build', '-trimpath', '-ldflags=-s -w', '-o', str(CACHE / 'egress-init'), '.'],
                   cwd=ROOT / 'egress', env=dict(os.environ, GOOS='linux', GOARCH='arm64', CGO_ENABLED='0'), check=True)
    files = [(p, stat.S_IFDIR | 0o755, b'') for p in ['proc', 'sys', 'dev', 'tmp', 'modules']]
    files += [('init', stat.S_IFREG | 0o555, (CACHE / 'egress-init').read_bytes()),
              ('cloudflared', stat.S_IFREG | 0o555, binary.read_bytes()),
              ('config.yml', stat.S_IFREG | 0o444, b'{}\n')]
    with tarfile.open(kernel, 'r:gz', ignore_zeros=True) as archive:
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
        for name in order:
            files.append(('modules/' + Path(name).name.removesuffix('.gz'), stat.S_IFREG | 0o444,
                          gzip.decompress(archive.extractfile(prefix + name).read())))
        files.append(('modules/order', stat.S_IFREG | 0o444,
                      '\n'.join(Path(n).name.removesuffix('.gz') for n in order).encode()))
    RES.joinpath('egress-initramfs.gz').write_bytes(prepare.cpio(files))
    print('NICなし通信VMの同梱準備完了')


if __name__ == '__main__':
    main()
