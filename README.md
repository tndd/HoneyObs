# HoneyObs

Apple Silicon Macの隔離VMで模擬HTTPサービスを動かし、受信・拒否・観測記録を表示するmacOSアプリです。AppKitとmacOS同梱WKWebViewを使い、画面・地図・GeoIP・採用アイコンをアプリへ同梱します。実行にrepo、Python、Go、Node.jsを必要としません。

## 通常の利用

開発用の導入先は `~/Applications/HoneyObs.app` です。インストール済みアプリをFinderやランチャーから開きます。macOS 15以降・Apple Siliconを対象にしています。開発署名のため、Developer ID署名・公証済みの一般配布版とは扱いません。

「自己ペネ」はlocalhostだけへ固定20ケース、160件の連続送信、低速接続を送り、HTTP応答と実VMのログを照合します。右下の小さなシールドは新たに観測した受信・拒否に反応します。404を防御成功とは表示しません。申告IPを地理推定に利用せず、公開機能をネイティブ側でも無効化します。

公開にはインターネット接続が必要です。模擬VMに加えて通信VMを起動し、Linux cloudflaredで一時URLを取得します。表示する「公開URL取得済み」はURL取得の状態であり、外部からの到達を実証した状態ではありません。実外部経路の検証はlocalhost検証とは別ゲートです。

## 停止と隔離

- UI/Engineと独立監視役を二つの一時launchdジョブで所有し、期限付きの認証された接続で相互監視します。ログイン時の常駐、自動再起動、自動再公開は行いません。
- OFFでは最初に転送許可を取り消し、入口と既存Relayを閉じます。VM・通信仲介・制御I/O・ログFDの回収を確認するまで停止完了と表示しません。停止要求から8秒で確認できない場合は失敗を保持し、OS所有による回収へ移ります。
- 模擬VMは1vCPU/512MiB、通信VMは1vCPU/256MiB。両方ともNIC、共有ディレクトリ、永続ディスクがありません。通信VMの非特権プロセスにはseccomp等を適用し、固定API一回・固定edge・固定origin以外の接続を受け付けません。ホストcloudflaredへの代替経路はありません。
- 全監視役の同時フリーズ、OS/カーネルの支配、VM脱出、許可済みCloudflareサービス内部のあらゆる不正利用まで防ぐ保証ではありません。

受入契約は [docs/safety-contract.md](docs/safety-contract.md)、通信境界は [docs/egress-isolation.md](docs/egress-isolation.md)、実証範囲は [docs/verification.md](docs/verification.md) を参照してください。過去の実装方針は [docs/safety-strategy.md](docs/safety-strategy.md) に履歴として残します。

## 観測と記録

観測は約1秒周期で取得し、画面に128件、保存に4096件を保持します。取得前の欠落・保存上限での破棄・取得待ちは別々に表示します。長いパスは512バイト以内とし、元の長さとSHA-256を残します。query・body・認証情報は保存しません。停止時は最大0.5秒だけ最終取得を試み、最終フェンスと保存の成立を「確定／部分取得／未確認」で区別します。

通常保存先は `~/Library/Application Support/HoneyObs/Sessions/<起動ID>/` です。所有者専用にし、7日・30セッション・256MiBの方針で過去分を整理します。利用中の記録はファイルロックで保護し、保存予算を確保できなければ開始を拒否します。旧版の `検証` 保存先や管理対象外のファイルは自動削除しません。

| ファイル | 内容 |
| --- | --- |
| `state.json` | 現在の動作・両VM・停止確認状態 |
| `events.json` | 観測、取得番号、既知の欠落・破棄 |
| `observation.json` | 入口／HTTP解析前の拒否理由、保持数、最終観測状態 |
| `final-observation.json` | セッションに結び付いた最終フェンス・取得・保存の結果 |
| `console.log` / `tunnel.log` | 各最大256KiBのVM診断リング |
| `owner.json` / `session-result.json` | 一時ジョブの所有と終了結果 |
| `exercise-report.json` | localhost自己ペネの突合結果 |

生IPと内部設定を含む記録を公開・Git管理しません。位置は同梱DB-IP Country Lite 2026年10月版の国単位の推定です。国の代表点であり、実際の発信地点やこのMacの現在地を示しません。予約・不明IPは地図に描かず記録には残します。GeoIPを外部照会しません。

## 開発と導入

開発にはSwift Command Line Tools、Go 1.24以降、Python 3が必要です。ビルド依存物のバージョンとSHA-256を固定します。

生成バンドルは `build/Applications.noindex/HoneyObs.app`、QAの私有コピーは各 `test-results` 内の `Applications.noindex` に置き、Spotlightへ開発版が重複表示されることを防ぎます。ログの保存先は変えません。通常利用する導入先は `~/Applications/HoneyObs.app` です。QA終了時のLaunch Services登録解除は別に検査します。

```sh
bash scripts/build.sh
python3 scripts/check_bundle.py
# 起動中のHoneyObsを終了してから導入
bash scripts/install.sh
open ~/Applications/HoneyObs.app
```

更新に失敗した場合の復旧、直前の版へのrollback、署名・公証・対応ソース提供の残るゲートは [docs/distribution.md](docs/distribution.md) を参照してください。

## 公開を伴わない検証

```sh
bash tests/unit.sh
npm ci && npx playwright install chromium && npm test
python3 tests/session_jobs.py
python3 tests/integration.py --local
bash tests/lifecycle.sh
bash tests/egress.sh --vm
bash tests/egress_engine.sh
python3 tests/self_pentest.py --close-after
python3 tests/app_background.py
```

`--headless` や `--ui-*` 等の検証用操作は明示した `--test-mode` と0700の私有保存先が必要です。通常起動は試験用環境変数・コマンドファイルを受け付けません。通信VMのfake edgeは `EGRESS_TESTING` を有効にした専用ビルドだけで使えます。

CI、専用実Macゲート、実外部経路、実スリープ、導入済みアプリの検証は [docs/quality-gates.md](docs/quality-gates.md) で区別します。ライセンスと出典は [third_party/README.md](third_party/README.md) に記載します。
