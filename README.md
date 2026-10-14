# HoneyObs — 内蔵VMと一時公開の技術検証

Apple Silicon Mac上で、小さなLinux VMをアプリに内蔵し、Cloudflareの一時URLから模擬HTTPサービスへ到達できるかを確かめる試作です。Docker、Python、Goのインストールは**完成したアプリを実行する側では不要**です。

ソースの公開先：[tndd/HoneyObs](https://github.com/tndd/HoneyObs)。

現段階はローカル署名した検証アプリです。一般配布用のDeveloper ID署名・公証は行っていません。macOS 15以降・Apple Siliconを対象とし、今回の実機はmacOS 15.8.1です。

## アプリの操作

`build/HoneyObs.app` をFinderから開きます。

- **ローカル検証**：内蔵VMを起動し、専用通信路と隔離状態を確認します。
- **一時公開を開始**：VMを起動し、同梱したcloudflaredで一時URLを発行します。URL経由の応答が確認できるまでは「公開中」にしません。
- **停止**：ローカル転送入口を閉じ、公開トンネルとVMを停止します。
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

世界地図、GeoIP DB、SQLiteによる長期保存、固定URL、Intel Mac、一般配布用インストーラは今回の技術検証には含みません。

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

## 検証

```sh
# 公開せず、実VMと通信隔離を確認
python3 tests/integration.py --local

# 一時公開を含む実経路の検証。終了時に公開を停止
python3 tests/integration.py

# ネイティブUIのボタン処理、画面画像、公開中のアプリ通常終了
python3 tests/ui_smoke.py
```

後者はCloudflareで複数の一時URLを発行します。通常停止、SIGKILLによるアプリ強制終了、スリープ通知ハンドラをそれぞれ公開状態から検査します。送信元確認は同じ公開ホストのCloudflare traceとIPv4で比較します。名前解決やTLS検証を迂回しません。

**スリープ通知の発火は実スリープの代替証明にはなりません。実スリープはユーザー指定により未実施です。**

再現用の記録は `test-results/verification-<日時>/` に出力します。結果と失敗時のログはGit管理対象外です。

今回の結果と検証範囲は [技術検証の結果](docs/verification.md) にまとめています。

## 依存元

- [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
- [cloudflared 2026.10.0](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.0)：Apache-2.0
- [Alpine linux-ltsのビルド定義](https://gitlab.alpinelinux.org/alpine/aports/-/tree/efc8ddbb20c827d2bd8223c19a2625e754e5cb3c/main/linux-lts)：使用パッケージlinux-virt 6.18.56-r0、LinuxはGPL-2.0-only

一般配布前には、同梱物のライセンス文書と対応ソースの提供、更新方式、Developer ID署名・公証を整える必要があります。
