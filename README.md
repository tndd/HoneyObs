# HoneyObs — 内蔵VMで観測するMacアプリ

Apple Silicon Mac上で、小さなLinux VMをアプリに内蔵し、Cloudflareの一時URLから模擬HTTPサービスへ到達できるかを確かめる試作です。Docker、Python、Goのインストールは**完成したアプリを実行する側では不要**です。

ソースの公開先：[tndd/HoneyObs](https://github.com/tndd/HoneyObs)。

現段階はローカル署名した検証アプリです。一般配布用のDeveloper ID署名・公証は行っていません。macOS 15以降・Apple Siliconを対象とし、今回の実機はmacOS 15.8.1です。

## アプリの操作

`build/HoneyObs.app` をFinderから開きます。

- **ローカル検証**：内蔵VMを起動し、専用通信路と隔離状態を確認します。
- **一時公開を開始**：VMを起動し、同梱したcloudflaredで一時URLを発行します。URL経由の応答が確認できるまでは「公開中」にしません。
- **停止**：ローカル転送入口を閉じ、公開トンネルとVMを停止します。
- **最近のアクセス**：行を選ぶとIP・日時・要求・応答と地図の経路を表示します。停止後も履歴を閲覧でき、次の起動操作で新しいセッションになります。
- ウィンドウを閉じるかアプリを終了した場合も停止します。常駐サービスはインストールしません。

一時URLのDNS反映に時間がかかる場合、公開確認を最大約3分再試行します。上限に達した場合は公開を停止してエラーを表示します。Quick Tunnelは試用向けであり、稼働保証はありません。

## 実装範囲

```text
外部のHTTPS要求
  → Cloudflare
  → 同梱cloudflared（Mac上、監視プロセス付き）
  → 127.0.0.1の転送入口
  → virtio socketの固定ポート7000
  → Linux VM内の模擬サービス

Mac → virtio socketの固定ポート7001 → 観測結果・隔離検査
```

VMは1 vCPU・512 MiBです。ネットワーク機器、共有フォルダ、永続ディスクは付けません。Linuxカーネルとinitramfsをアプリに同梱し、ホストからゲストの固定ポートにだけ接続します。ゲストから接続を開始するホスト側のvsockリスナーは作りません。

ゲストは初期化後にUID/GID 65534へ権限を落とします。ルート領域は読み取り専用、作業領域はメモリ上に置き、終了すると破棄されます。シェル・パッケージ管理ツール・外部コード実行機能は同梱しません。GoのHTTP処理で模擬応答だけを返します。

- `/login` は常に401、それ以外は404です。実際の認証やコマンド実行はしません。
- 本文は8 KiB以下、ヘッダーと通信時間も制限します。Mac側の転送は最大8接続、要求32 KiB、応答64 KiB、1接続6秒を上限とします。
- 本文、Cookie、認証ヘッダー、URLクエリは記録しません。
- 観測結果には時刻、メソッド、パス、送信元IP、応答コードを保存します。現在は最大128件の検証用リングバッファです。
- トンネルがHostヘッダーを起動ごとの値へ置換します。ローカル入口へ直接送った要求はこの値が一致しなければ403です。同じMacの同一ユーザーによる侵害まで防ぐ認証ではありません。
- 送信元IPはトンネル経路の`CF-Connecting-IP`から読み取ります。偽の`X-Forwarded-For`を信用しないことを実公開テストで確認します。訪問者自身が付けた`CF-Connecting-IP`は、Cloudflare側で403・エラー1000として拒否されるため、VMには届きません。
- アプリの強制終了を別プロセスが検出し、cloudflaredを終了・回収します。監視プロセス自体の同時強制終了まで含む耐障害性は今回の対象外です。

画面は採用した「シアン監視室」を基に、AppKitのウィンドウとmacOS同梱のWKWebViewで表示します。画面・日本中心の世界地図・国別GeoIPはアプリに同梱し、画面表示のためのHTTPサーバーや外部CDNは使いません。公開トンネルにはインターネット接続が必要です。

VMの観測結果を約1秒ごとに回収し、最新128件を一覧・詳細・地図へ反映します。新規受信と行の選択で経路をアニメーション表示し、OSの「視差効果を減らす」設定では動きを抑えます。公開確認用の要求には「確認用」を付けます。この区分はパスの接頭辞による表示であり、送信者の信頼性判定ではありません。

位置は同梱したDB-IP Country Lite 2026年10月版から**国単位で推定**します。地図の点は国の代表位置で、実際の発信地点ではありません。日本の終点も表示上の観測点であり、このMacの位置を取得したものではありません。予約IP・判定不能なIP・地図に形状がない地域は位置を描かず、一覧には残します。VPN・プロキシの利用などで推定国が実際の利用者と異なる場合があります。

SQLiteによる長期保存、固定URL、Intel Mac、一般配布用インストーラは今回の範囲に含みません。

## 記録の場所

通常起動では `~/Library/Application Support/HoneyObs/検証/<起動ID>/` に保存します。ディレクトリは所有者のみアクセス可能にします。

- `state.json`：現在の状態、プロセスID、公開URL
- `events.json`：最大128件の観測結果。変更があったときだけ保存
- `isolation.json`：ゲスト内部からの通信・書き込み検査結果
- `console.log`：VMの起動ログ
- `tunnel.log`：公開用トンネルの診断ログ（256 KiBを超える前に古い内容を破棄）
- `watchdog.json`：監視・トンネルのプロセスID

生のIPや起動時の内部設定を含むため、これらは公開・Git管理しません。今回の検証は短時間の利用を想定し、長期運用向けの古いセッションの整理は別途必要です。

## 開発者向けビルド

開発時はSwiftのCommand Line Tools、Go 1.24以降、Python 3が必要です。これらを実行利用者に要求する構成ではありません。

```sh
bash scripts/build.sh
open build/HoneyObs.app
```

依存物はバージョンとSHA-256を固定して取得します。AlpineのEFI圧縮イメージからAppleの直接起動用ARM64 Linux Imageを取り出し、必要なvsockモジュールと専用プログラムだけのinitramfsを生成します。

GeoIPもビルド時に取得・検証し、IPv4/IPv6の固定長範囲データへ変換して同梱します。実行時にIPを外部照会しません。DB更新時には `scripts/prepare_gui.py` の版・SHA-256と `GeoIP.edition` を合わせて更新します。

`Resources/Brand/AppIcon.png` は採用アイコンのビルド入力、`Resources/Dashboard/world-map.js` はアプリが直接利用する地図資産です。インストール後の外部取得をなくすためGit管理します。検証スクリーンショットとは区別しています。地図を再生成する開発者だけはNode.jsで `node scripts/build_map.cjs` を実行します。通常のアプリビルドにNode.jsは不要です。

## 検証

```sh
# 公開せず、実VMと通信隔離を確認
python3 tests/integration.py --local

# 一時公開を含む実経路の検証。終了時に公開を停止
python3 tests/integration.py

# ネイティブUIのボタン処理、画面画像、公開中のアプリ通常終了
python3 tests/ui_smoke.py

# 実アプリの公開ボタン→実受信→国照会・地図・行選択→停止・再開
python3 tests/dashboard_smoke.py

# 同梱DBと合成した範囲境界、予約IP、イベント変換
swiftc Sources/HoneyObs/GeoIP.swift Sources/HoneyObs/ObservedEvent.swift tests/GeoIPChecks.swift -o .cache/geoip-tests
.cache/geoip-tests build/HoneyObs.app/Contents/Resources

# 画面の補助検証（開発時のみNode.js・Playwrightを使用）
npm ci
npx playwright install chromium
npm test
```

公開を含むテストはCloudflareで一時URLを発行します。`integration.py` は通常停止、SIGKILLによるアプリ強制終了、スリープ通知ハンドラをそれぞれ公開状態から検査します。送信元確認は同じ公開ホストのCloudflare traceとIPv4で比較します。名前解決やTLS検証を迂回しません。

**スリープ通知の発火は実スリープの代替証明にはなりません。実スリープはユーザー指定により未実施です。**

再現用の記録は `test-results/verification-<日時>/` に出力します。結果と失敗時のログはGit管理対象外です。

今回の結果と検証範囲は [技術検証の結果](docs/verification.md) にまとめています。

地図・国別IPデータの版、出典、加工内容は [同梱物の出典](third_party/README.md) に記載しています。

## 依存元

- [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
- [cloudflared 2026.10.0](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.0)：Apache-2.0
- [Alpine linux-ltsのビルド定義](https://gitlab.alpinelinux.org/alpine/aports/-/tree/efc8ddbb20c827d2bd8223c19a2625e754e5cb3c/main/linux-lts)：使用パッケージlinux-virt 6.18.56-r0、LinuxはGPL-2.0-only

一般配布前には、同梱物のライセンス文書と対応ソースの提供、更新方式、Developer ID署名・公証を整える必要があります。
