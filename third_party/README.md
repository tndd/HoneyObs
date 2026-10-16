# 同梱物の出典

- `cloudflared-LICENSE`：cloudflare/cloudflared、タグ2026.10.0のLICENSE。Apache-2.0の原文です。
- `linux-COPYING`、`linux-GPL-2.0`：torvalds/linux、タグv6.18のライセンス原文です。

使用した実バイナリのバージョン・取得URL・チェックサムは `scripts/prepare.py` と `scripts/prepare_egress.py` に固定しています。LinuxパッケージはAlpineのlinux-virt 6.18.56-r0（aarch64）です。ビルド定義はAlpine aportsコミット `efc8ddbb20c827d2bd8223c19a2625e754e5cb3c` の `main/linux-lts` にあります。

このディレクトリはビルド時にアプリのResources/Licensesへコピーします。一般配布に先立ち、Linuxの対応ソースとビルド用変更の提供方法を整備してください。ライセンス文書の同梱だけで対応ソース提供まで完了したとは扱いません。

## 地図・国別IPデータ

- [DB-IP Country Lite](https://db-ip.com/db/download/ip-to-country-lite)：2026年10月版、CC BY 4.0。原文は `DB-IP-CC-BY-4.0.txt`。取得元は `https://download.db-ip.com/free/dbip-country-lite-2026-10.csv.gz`。画面下部にもDB-IPへのリンクを表示します。
- 変更内容：開始IP・終了IP・国コードのCSVを、IPv4/IPv6別の固定長バイナリへ変換。予約IPを表示時に除外し、国コードから国の代表点へ対応付けます。都市精度のデータではありません。
- 取得したgzipのSHA-256は `097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80`。展開CSVのSHA-1は公開ページの `c8ad1dfe98cb29bcacd82a5c3ec361c880e5bb59` と一致しました。
- [Natural Earth](https://www.naturalearthdata.com/about/terms-of-use/) のパブリックドメイン地理データを [world-atlas 2.0.2](https://github.com/topojson/world-atlas) 経由で取得。world-atlasのISCライセンスは `world-atlas-LICENSE` に同梱します。110m国境を日本中心に投影し、SVGパスと代表点へ変換しています。小さな島嶼地域などは省略されます。
- [i18n-iso-countries 7.14.0](https://github.com/michaelwittig/node-i18n-iso-countries) の国コード対応表：MIT、原文は `iso-countries-LICENSE`。数値国コードをISO alpha-2へ変換する際に使用します。
- 地図再生成時だけD3 7.9.0とtopojson-client 3.1.0を使用します。これらの実行コードはアプリに含めません。生成入力のチェックサムは `scripts/map-sources.json` に固定しています。
