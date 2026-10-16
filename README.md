# HoneyObs — 内蔵VMで観測するMacアプリ

Apple Silicon Mac上で、小さなLinux VMをアプリに内蔵し、Cloudflareの一時URLから模擬HTTPサービスへ到達できるかを確かめる試作です。Docker、Python、Goのインストールは**完成したアプリを実行する側では不要**です。

ソースの公開先：[tndd/HoneyObs](https://github.com/tndd/HoneyObs)。

現段階はローカル署名した検証アプリです。一般配布用のDeveloper ID署名・公証は行っていません。macOS 15以降・Apple Siliconを対象とし、今回の実機はmacOS 15.8.1です。

## アプリの操作

`~/Applications/HoneyObs.app` をFinderのアプリケーションから開きます。初回の導入は開発者向けビルドの手順で行います。導入後はrepoやターミナル、Pythonを起動する必要はありません。

- **自己ペネ**：localhost限定で20ケース・160件の連続送信・低速接続と回復を実行し、応答とログ照合を表示します。中止後も結果を見られ、通常画面へ戻るか再実行できます。外部トンネルは起動しません。
- **ローカル検証**：内蔵VMを起動し、専用通信路と隔離状態を確認します。
- **一時公開を開始**：VMを起動し、同梱したcloudflaredで一時URLを発行します。URL経由の応答が確認できるまでは「公開中」にしません。
- **停止**：ローカル転送入口を閉じ、公開トンネルとVMを停止します。終了確認中は「停止処理中」、確認できた場合だけ「停止完了」と表示します。停止APIの失敗や8秒の待機期限超過では「停止失敗」とし、再開を禁止します。
- **最近のアクセス**：行を選ぶとIP・日時・要求・応答と地図の経路を表示します。停止後も履歴を閲覧でき、次の起動操作で新しいセッションになります。
- ウィンドウを閉じるかアプリを終了した場合も、停止完了を待って終了します。終了未確認の場合は終了要求を取り消し、画面で状態を示します。常駐サービスはインストールしません。

VM準備完了後に観測応答が5秒以上途絶えた場合も停止します（1秒周期の確認）。これらはメインスレッドが動作する通常の停止経路の強化であり、アプリ全体や監視役のフリーズ、監視役自身の強制終了からの完全な回収を保証するものではありません。全体の実装戦略と残る保証範囲は [安全性の実装戦略](docs/safety-strategy.md) に記載しています。

公開・自己ペネの転送中は、画面とVMの新しい応答に対する3秒の許可を使用します。Relay自身も期限を検査し、メイン処理が固まった場合に既存接続を閉じます。公開時のwatchdogとも専用パイプで確認し、アプリ全体の停止時にもトンネル終了を試みます。全プロセス・VMの完全回収保証と、通信先制限には残る課題があり、詳細は上記の実装戦略を参照してください。

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
- 観測結果には時刻、メソッド、パス、送信元IP、応答コードを保存します。VMとMacでそれぞれ最大4096件を保持し、番号を追って128件ずつ取得します。上限を超えた取得前の欠落と保存済み記録の破棄は、別々の件数として表示します。
- トンネルがHostヘッダーを起動ごとの値へ置換します。ローカル入口へ直接送った要求はこの値が一致しなければ403です。同じMacの同一ユーザーによる侵害まで防ぐ認証ではありません。
- 送信元IPはトンネル経路の`CF-Connecting-IP`から読み取ります。偽の`X-Forwarded-For`を信用しないことを実公開テストで確認します。訪問者自身が付けた`CF-Connecting-IP`は、Cloudflare側で403・エラー1000として拒否されるため、VMには届きません。
- アプリの強制終了を別プロセスが検出し、cloudflaredを終了・回収します。監視プロセス自体の同時強制終了まで含む耐障害性は今回の対象外です。

画面は採用した「シアン監視室」を基に、AppKitのウィンドウとmacOS同梱のWKWebViewで表示します。画面・日本中心の世界地図・国別GeoIPはアプリに同梱し、画面表示のためのHTTPサーバーや外部CDNは使いません。公開トンネルにはインターネット接続が必要です。

VMの観測結果を約1秒ごとに回収し、最新128件を一覧・詳細・地図へ反映します。新規受信と行の選択で経路をアニメーション表示し、OSの「視差効果を減らす」設定では動きを抑えます。パスや外来ヘッダーだけで「確認用」と判定しません。内部の公開確認要求も通常の受信として表示します。長いパスは512バイト以内へ省略し、元の長さ・省略の有無・元のEscapedPathのSHA-256を残します。query・body・認証情報は保存しません。

位置は同梱したDB-IP Country Lite 2026年10月版から**国単位で推定**します。地図の点は国の代表位置で、実際の発信地点ではありません。日本の終点も表示上の観測点であり、このMacの位置を取得したものではありません。予約IP・判定不能なIP・地図に形状がない地域は位置を描かず、一覧には残します。VPN・プロキシの利用などで推定国が実際の利用者と異なる場合があります。

SQLiteによる長期保存、固定URL、Intel Mac、一般配布用インストーラは今回の範囲に含みません。

## 記録の場所

通常起動では `~/Library/Application Support/HoneyObs/検証/<起動ID>/` に保存します。ディレクトリは所有者のみアクセス可能にします。

- `state.json`：現在の状態、プロセスID、公開URL
- `events.json`：最大4096件の観測結果と取得番号・欠落数・保存上限による破棄数・VM側拒否集計。変更があったときだけ保存
- `observation.json`：VM側とMac入口の拒否理由別件数・最終時刻、保持／欠落／破棄／取得待ち件数。HTTP未解析の拒否には、信頼できる送信元IPやパスを推測で付けません
- `isolation.json`：ゲスト内部からの通信・書き込み検査結果
- `console.log`：VMの起動ログ
- `tunnel.log`：公開用トンネルの診断ログ（256 KiBを超える前に古い内容を破棄）
- `watchdog.json`：監視・トンネルのプロセスID

生のIPや起動時の内部設定を含むため、これらは公開・Git管理しません。今回の検証は短時間の利用を想定し、長期運用向けの古いセッションの整理は別途必要です。

## 開発者向けビルド

開発時はSwiftのCommand Line Tools、Go 1.24以降、Python 3が必要です。これらを実行利用者に要求する構成ではありません。

```sh
bash scripts/build.sh
bash scripts/install.sh
open ~/Applications/HoneyObs.app
```

依存物はバージョンとSHA-256を固定して取得します。AlpineのEFI圧縮イメージからAppleの直接起動用ARM64 Linux Imageを取り出し、必要なvsockモジュールと専用プログラムだけのinitramfsを生成します。

GeoIPもビルド時に取得・検証し、IPv4/IPv6の固定長範囲データへ変換して同梱します。実行時にIPを外部照会しません。DB更新時には `scripts/prepare_gui.py` の版・SHA-256と `GeoIP.edition` を合わせて更新します。

`Resources/Brand/AppIcon.png` は採用アイコンのビルド入力、`Resources/Dashboard/world-map.js` はアプリが直接利用する地図資産です。インストール後の外部取得をなくすためGit管理します。検証スクリーンショットとは区別しています。地図を再生成する開発者だけはNode.jsで `node scripts/build_map.cjs` を実行します。通常のアプリビルドにNode.jsは不要です。

## GUIでlocalhost自己ペネを見る

インストールしたHoneyObsの「自己ペネ」を押します。実VMに固定の20ケース・160件の連続送信・低速接続を送り、試験名、実際のHTTP応答、ログとの照合結果を順次表示します。実行時にPythonやrepoを使用しません。観測は約1秒周期で、右下の小さなシールドは新しく観測した受信・拒否に反応します。404を防御成功とは表示しません。

入口は127.0.0.1だけで待ち受け、cloudflaredを起動しません。公開操作をネイティブ側でも無効化し、「自己ペネを中止」やアプリ終了でVMと入口を停止します。結果画面から「通常画面へ戻る」または再度「自己ペネ」を選べます。結果はアプリのセッションディレクトリの `exercise-report.json` に保存します。ヘッダーの申告IPを地理推定に使用しません。

開発者向けの独立した回帰試験 `python3 tests/self_pentest.py --gui` も引き続き使えます。こちらは試験用Runnerを使用し、生成物を `test-results/self-pentest-*/` に保存します。

## 検証

```sh
# 公開せず、実VMと通信隔離を確認
python3 tests/integration.py --local

# 実VMの起動途中停止・停止失敗・無応答・遅着通知・応答期限
bash tests/lifecycle.sh

# 実アプリの終了待機・監視役異常終了の未確認表示（一時トンネルを起動）
python3 tests/stop_edges.py

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
node tests/live_dashboard.cjs

# 実GUIから自己ペネを中止し、VM・入口の停止を確認
python3 tests/live_pentest_cancel.py

# 導入済みアプリの自己ペネ・GUI中止・repo非参照
python3 tests/installed_app.py

# 実VMと通信しないトンネル子で、フリーズと期限切れを検証
python3 tests/permit_faults.py
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

### localhost自己ペネ

`python3 tests/self_pentest.py` は実VM・製品Relay・観測取得処理へ20ケースと短時間160件、低速8接続を送り、応答と記録を照合します。試験用Engineの起動箇所だけを差し替え、127.0.0.1へ限定し、外部トンネルは起動しません。先に `bash scripts/build.sh` を実行してください。結果のディレクトリを指定して `node tests/self_pentest_ui.cjs test-results/self-pentest-...` を実行すると、実ログの行選択・省略表示・拒否集計・偽装ラベルが付かないことを画面でも確認します。

拒否したHostは403イベントとして記録し、HTTPパーサーの拒否・読取期限はVM内で、接続数上限や中継上限はMac側で理由別に集計します。これらの集計は要求イベントとは別の指標で、単純に足して「攻撃数」とは扱いません。拒否の生データは保存せず、Cloudflareで止まった通信もこのログの対象外です。記録は有界のセッション内観測で、無期限の監査保管ではありません。停止直前の未取得データは回収保証の対象外で、停止完了を優先します。
