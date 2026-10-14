# 同梱物の出典

- `cloudflared-LICENSE`：cloudflare/cloudflared、タグ2026.10.0のLICENSE。Apache-2.0の原文です。
- `linux-COPYING`、`linux-GPL-2.0`：torvalds/linux、タグv6.18のライセンス原文です。

使用した実バイナリのバージョン・取得URL・チェックサムは `scripts/prepare.py` に固定しています。LinuxパッケージはAlpineのlinux-virt 6.18.56-r0（aarch64）です。ビルド定義はAlpine aportsコミット `efc8ddbb20c827d2bd8223c19a2625e754e5cb3c` の `main/linux-lts` にあります。

このディレクトリはビルド時にアプリのResources/Licensesへコピーします。一般配布に先立ち、Linuxの対応ソースとビルド用変更の提供方法を整備してください。ライセンス文書の同梱だけで対応ソース提供まで完了したとは扱いません。
