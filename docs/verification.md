# 検証記録

## Alfredの重複解消と生成アプリの索引除外（2026-10-17、PR #27）

開発・QAの `.app` が検索対象に残り、Alfredに複数のHoneyObsが表示されていた。生成先を `build/Applications.noindex/HoneyObs.app` と各QA runの `Applications.noindex/` へ統一し、導入時のstage・前版・復旧用の保持版も `~/Applications/Applications.noindex/` 配下へ置く。通常の導入先は `~/Applications/HoneyObs.app`。ログ・state・reportのrunパスは維持する。

既知の開発・QA bundle 23件は、所有範囲・ID・実行ファイル・symlink・稼働プロセスを確認して同じfilesystemの索引外へ移し、移動前後の内容hash一致を確認した（`test-results/launcher-migration-20261017-092149.json`）。削除や索引/LaunchServices全体のリセットは行っていない。利用者からもAlfredでの解消を確認済み。実装統合点 `8927fd3` の検証は次の通り。

| 検証 | 結果と証拠 |
| --- | --- |
| 単体・導入復旧・QA境界 | `bash tests/unit.sh` 合格。導入復旧18件、QA境界21件を含む。旧backup移行・衝突・main/helper稼働中・symlink/別filesystemの拒否・失敗時の版の保持を確認（`test-results/launcher-final-unit.log`） |
| 未登録fixtureの判定 | 初回の実Mac回帰では、索引外の非GUI fixtureに対する登録解除が-10814となり正しく失敗した。CLI結果だけでは成功にせず、公開APIで正確なURLの不在を独立確認する場合だけ受理する修正を追加。登録残存・照会失敗・差替えは失敗を維持し、実 `session_jobs` の再検証も合格（`test-results/session-jobs-20261017-092842-79c139/`） |
| ブラウザ | `npm test` と `node tests/live_dashboard.cjs` 合格。選択、HTML表示、128件、右下シールド、応答と記録の分離、中止、縮小画面、動き軽減、外部通信なしを確認（`test-results/launcher-browser.log`） |
| 実Macの各回帰項目 | 新配置でビルド/署名、制御、独立job、VM隔離、停止I/O、権限、通信VM、Relay取消、最終観測、所有故障、localhost自己ペネ20ケース/160要求/低速接続、最小化・非表示が合格（`test-results/launcher-full-gate-final.log`） |
| 実メニューと失効 | 上記一括実行はメニューが4.2秒前に閉じてexit 1となった。入力/前面切替の観測後、利用者が操作を控えた別実行で同じソースのメニュー保持4.449秒、UI/guest freshness、HTTP、同じjob、VM回収が合格。続くmain/UI停止による失効・既存接続終了・新規拒否も合格（`test-results/menu-tracking-20261017-094546-3e110c/`、`test-results/permit-faults-20261017-094719/`）。一括script自体のexit 0とは区別する |
| 実際の更新と通常起動 | 旧0.3.0 build 4をhash/署名を保って索引外へ退避し、新installerで0.3.1 build 5を導入。直前版も索引外にあり、stage残存なし、正式版/直前版/退避版の深い署名検証が合格。`/tmp` から通常起動し、導入先と実行先、アイコン、repo非参照、重複起動の同じPID、Quit時の両job/IPC消滅、再起動後の待機/VMなしを確認（`test-results/launcher-installed-layout.json`、`test-results/normal-installed-20261017-094802/`） |
| 最終索引・登録 | 名前とBundle IDの両索引検索、および公開APIの登録URLが正式版1件のみ。退避した旧版の残存登録はその正確なURLだけ解除し、fixtureの未登録も確認した。最終状態は通常アプリの待機中、公開なし、両VMなし（`test-results/launcher-final-receipt.json`） |

外部公開経路、実スリープ、VM基盤の脱出耐性、配布用署名・公証の未検証範囲は、この変更では回収しない。Issue #2を継続する。

## 追加レビュー5件の修正（2026-10-17、0.3.1 build 5）

[PR #25の追加レビュー](https://github.com/tndd/HoneyObs/pull/25#issuecomment-6222966553)を対象に、修正前の再現と修正後の回帰を追加した。環境はApple Silicon・macOS 15.8.1・Swift 6.2.4、製品コードの統合点は `fa19e39`。後続のQA・文書変更は別途記録する。

| 指摘 | 修正と検証 |
| --- | --- |
| 失効後の新規送信 | NW send/startの発行を取消・許可検査と直列化し、blocking read後も再検査。実socketpair＋localhost NWで期限後送信・最終read・cancel/revoke競合の4群が合格。旧実装では期限後のpayload送信と期限跨ぎreadの受理を再現。`tests/egress_revocation.sh` を単体CIへ接続 |
| メニュー操作による誤失効 | 所有/UI/VM/停止のTimerをcommon modesへ登録。旧SessionClientは実NSMenu追跡中にjob消滅、新版は追跡4.2秒を維持し、main停止は引き続き失効。製品WKWebViewと実VMでもtracking中/後のHTTP、UI/guest時刻、許可、同じPID/生成時刻と両jobの維持、終了後の回収を確認 |
| 保存の期限超過を確定 | 20ms予算/40ms保存の旧実装は実測52ms主キューを塞いでconfirmed。修正後はstart復帰3ms、23msでpartial、sealed=false。保存中も期限通知が進み、遅着で確定へ戻らない。実VMではwriterを止めたまま約0.669秒でVZ helper消滅を独立観測し、I/O回収前の停止完了/再開/停止再試行を拒否 |
| 異常終了記録の早期削除 | 監視役のrecovery lockと、初回中断観測から600秒の猶予を追加。旧版の長時間セッション即削除・遅い結果保存失敗を再現し、新版は保護して保存成功。監視役停止中もprune拒否、599秒保持/601秒回収、実再開時の中断時刻解除を確認 |
| 登録解除失敗の偽PASS | 各harnessで成功report/PASSより前に明示cleanupし、失敗を非zeroへ伝播。失敗対象だけatexitで再試行。実integration.mainを使う子Pythonの合成bundle/偽lsregister試験3件は旧実装をすべて拒否。対象限定・導入済み拒否・差替え拒否も維持 |

初回の全体回帰では、背景化試験の開始前に通常ウィンドウを表示できない準備失敗と、子が解除済みのbuildアプリを親ゲートが二重解除する失敗を検出した。前者はread-onlyのOS状態で `CGSSessionScreenIsLocked=1`、前面が `com.apple.loginwindow` と確認した。固有Bundle IDへの変更や前面化APIでは解消せず、起動先の競合とは断定しない。ウィンドウの判定条件は緩和せず、解除後の再検証が必要である。後者は所有する各harnessの明示cleanupへ統一して重複解除を除いた。これらの初回失敗を合格に読み替えない。

後続のQA統合点 `fe3093a` でも `bash tests/unit.sh` が合格し、導入復旧12件・QA境界11件を含めて確認した（`test-results/review26-final-unit.log`）。背景検査はread-onlyの開始前検査を追加し、ロック中の実機でApp/VMを起動せずexit 1、PASSなし、cases空を確認した（`test-results/app-background-20261017-050258-fe8d0a/report.json`）。

利用者のロック解除後、`d6621e9` を固定して `bash scripts/local_vm_gate.sh` がexit 0で全完走した（`test-results/review26-unlocked-full-gate.log`）。最小化・非表示はそれぞれ実native bounds/hidden状態とfreshness・HTTP・VZ回収を確認した（`test-results/app-background-20261017-091535-ff07ff/`）。実NSMenuの4.2秒保持は `test-results/menu-tracking-20261017-091604-f4c53a/`、UI/main停止による失効・既存接続終了・失効後の新規拒否は `test-results/permit-faults-20261017-091614/` に記録した。初回のロック中失敗を再解釈したものではなく、解除後の別実行である。

0.3.1 build 5を `~/Applications/HoneyObs.app` へ更新し、`tests/installed_app.py` の完走・即中止・IP観測後中止の3経路が合格した（`test-results/installed-app-20261017-091653/`）。完走/中止画面も目視確認した。さらに `/tmp` から試験フラグなしで通常起動し、NSRunningApplication・Engine・ownerのPID一致、導入済みbundleと実行先、アイコン、repo非参照、重複起動の同じPID、通常Quitによる両job/IPC消滅、再起動後の待機/VMなしを確認した（`test-results/normal-installed-20261017-091814/`）。これでPR #26で保留していた実機受入2条件を回収した。

別途、利用者から報告されたSpotlightの重複は、登録解除と別に開発/QAの `.app` 自体が索引に残る問題と確認した。生成bundleの配置・旧コピーの移行は後続の変更で扱い、登録解除失敗の偽PASSの修正だけを重複解消の証拠にしない。

局所証拠：`test-results/review26-before/slow-persist.json`、`test-results/review26-bin/slow-persist.json`、`test-results/lifecycle-3B23D317-16A2-47EA-8492-AA46987635DD/`、`test-results/session-jobs-20261017-044514-0dd5d5/`、`test-results/menu-tracking-20261017-045213-d2b2be/`、`test-results/permit-faults-20261017-045223/`。修正前後の追加証拠は `test-results/review26-evidence/` に保存した。外部公開・実スリープ・一般配布の未回収ゲートは継続する。

## 2VM・OS所有構成の初期統合（2026-10-17、PR #25）

この節はPR #25時点の記録である。後続の2026-10-15〜17の節も各時点の構成の履歴であり、旧host cloudflaredの公開成功を新しい通信VMの外部経路成功へ読み替えない。

対象はApple Silicon・macOS 15.8.1・Swift 6.2.4、PR #25の製品ソース `14a90d5`、0.3.0 build 4のローカル署名版。同PR内の後続変更は試験ハーネス・導入スクリプト・CI・文書である。

| 検証 | 結果と証拠 |
| --- | --- |
| 実Mac一括ゲート | `bash scripts/local_vm_gate.sh` 合格。ビルド、深い署名、同梱資産、制御CLI、独立ジョブ、localhost隔離、停止API故障、権限制限、通信VM、Relay取消、最終観測、所有故障、自己ペネ、背景動作を実行 |
| 自己ペネと記録照合 | 20ケース、160要求の一括送信、低速接続の上限・拒否・回復を確認。`test-results/self-pentest-20261017-035355-9741ed/report.json` |
| 停止直前の記録 | seedと末尾128件を全ページ取得し、応答・ID・パス・本文SHAを照合。未完了Relayも停止し、フェンス成立・保存成功・未確認末尾なし。停止完了816ms、VZ helper消滅886ms。`test-results/final-observation-20261017-035219/report.json` |
| 単一故障と独立OS観測 | 通常終了、UI/監視役のKILL/STOP、起動中STOP、両VZ helperのKILL/STOPの全10ケース合格。cleanup前にジョブ・PID生成時刻・helper・IPCを確認。`test-results/session-ownership-20261017-035232/report.json` |
| 期限後の追加要求 | 上記に加えてUI/監視役のKILL/STOP各4ケースで3.260秒後のnonce付き新規HTTPと既存POST残本文へ応答なし。`test-results/session-ownership-20261017-035544/report.json` |
| 権限と固定通信境界 | 実Linux VMでGoの複数スレッド・exec後もNoNewPrivs/seccompが維持されることを確認。通信VMのNIC・共有・ディスクなし、禁止経路拒否、固定localhost偽API/edge経由の2VM疎通と停止が合格。実Cloudflare TLSは未実施 |
| 背景動作 | 最小化・Stage Managerの縮小表示・非表示でも余分なJS評価なしでfreshnessを維持し、復帰後とOFF後のVZ回収を確認。`test-results/app-background-20261017-035501-b68130/report.json` |
| 画面と主スレッドの停止 | 同一build 4の私有コピーで、main 5秒停止とJS無限ループの2件が合格。3.25秒後の新規HTTP・既存POST残本文に応答なし。TCP EOFは2.189秒/2.975秒。停止後の非復活、JS停止中のnative応答、通常終了とjob/VM回収を確認。`test-results/permit-faults-20261017-040026/report.json` |
| 通常の導入済みアプリ | `~/Applications/HoneyObs.app` を `/tmp` からLaunch Services起動し、repo非参照、同梱資産、採用アイコン、20ケース完走・途中中止・IP偽装後の中止と画面復帰が合格。完了・中止の実WKWebView画像を目視確認。`test-results/installed-app-20261017-035612/report.json` |
| 試験フラグなしの通常起動 | 起動先が導入済み.appであること、実行中アイコンの128px画素一致、regularアプリ1個、重複openで同一PID、通常Quit後の両job/IPC消滅、再起動を確認。再起動後は公開せずidle表示。初期launcherと実UIを区別するためEngine state・所有clientPID・NSRunningApplicationの一致を待つ。`test-results/installed-normal-20261017-0405/report.json` |
| 単体とPlaywright | `bash tests/unit.sh`、`npm test`、`node tests/live_dashboard.cjs` 合格。期限、遅着、取得失敗、保存容量・排他、console上限、導入/復旧12件、QA登録の対象限定5件、右下shield・中止・縮小画面・通信なしを確認 |

3秒は許可の期限でありTCP切断期限ではない。全10ケースのUI SIGSTOPではEOF 4.022秒、VZ helper STOPの全回収は最大16.594秒だった。期限後の追加要求拒否、EOF、全OS資源回収を別の測定として残し、「3秒／8秒で全プロセス消滅」とは扱わない。すでにOSへ渡したデータの撤回、OS停止や信頼する全監視役の同時停止への無条件保証はない。

実Cloudflare経路と独立した外部端末、実スリープ短/長・復帰、ログアウト、CPU/メモリ圧迫下の期限、VM/OSの未知脆弱性、一般配布は未回収である。Developer ID・公証・Gatekeeper・対応ソース提供を、開発署名やlocalhostの合格で代用しない。設計契約は [停止・隔離・観測の共通契約](safety-contract.md)、実行手順は [品質ゲート](quality-gates.md) を参照。

## 初期の内蔵VM・一時公開の技術検証結果

実施日：2026年10月15日（日本時間）

環境：Apple Silicon、macOS 15.8.1、Swift 6.2.4。アプリはローカル署名です。一般配布向けのDeveloper ID署名・公証は未実施です。

## 結果

| 検証項目 | 結果 | 観測したこと |
| --- | --- | --- |
| 内蔵VMの起動と専用通信路 | 合格 | アプリに同梱したLinuxとinitramfsを起動し、virtio socket越しにHTTP応答と観測結果を回収 |
| 一時公開の実経路 | 合格 | 通常のDNS・TLS検証を使い、公開HTTPS URL → Cloudflare → Mac → VMを通過。要求したパスの観測と模擬応答を確認 |
| 送信元IP | 合格 | IPv4に揃え、同じ公開ホストのCloudflare traceが示すIPとVMの記録が一致 |
| 偽のX-Forwarded-For | 合格 | 任意のIPを送っても、VMに記録されたIPは実際の接続元と一致 |
| 偽のCF-Connecting-IP | 合格 | Cloudflareが403・エラー1000で拒否し、該当要求がVMのイベントに存在しない |
| 本文・クエリの扱い | 合格 | クエリの検査文字列を保存しない。8 KiB超の本文は413。ログイン要求は401 |
| ローカル入口への直接アクセス | 合格 | 起動ごとのHost値を持たない要求を403で拒否 |
| 通常停止 | 合格 | ローカル入口が閉じ、監視・トンネルのプロセスが終了。公開URLはVMの応答を返さず530になった |
| アプリ強制終了 | 合格 | SIGKILL後も監視がcloudflaredを回収。入口の閉鎖と公開URLからVMへ到達できないことを確認 |
| ネイティブアプリの通常終了 | 合格 | 公開状態からNSApplicationの終了経路を通し、アプリ・監視・トンネルの終了と公開停止を確認 |
| スリープ通知ハンドラ | 合格 | NSWorkspaceの通知センターへ同じ通知を送って停止処理を実行。入口・トンネル・公開応答の停止を確認 |
| **実際のMacのスリープと復帰** | **未検証** | ユーザー指定により実行しない。上記の通知テストでは実スリープ後のOS挙動まで証明しない |
| 通信とファイルの隔離 | 合格 | VMのNIC・共有フォルダ・ディスクは0。サービスUIDは65534。ルート領域への書き込みは読み取り専用エラー。9種類の接続プローブが失敗 |

接続プローブには、稼働中のMac側ループバック待受、MacのLANアドレス、LAN側IP、外部IP、IPv6ループバック、ホスト側vsockの3ポートを含みます。IPv4の外部・Mac宛てはnetwork is unreachable、ホストvsockはconnection resetでした。これらは構成と選択した経路の検査であり、仮想化基盤の脆弱性が存在しないことを証明するものではありません。

## 初期の最小画面（GUI追加前）

ローカル起動・停止、公開中の3状態について、AppKitのビュー画像を取得して目視確認しました。ボタンの処理はアプリ内のテスト入口からperformClickで呼び出しています。人による実クリックやOS全体のスクリーンキャプチャとは区別します。ブラウザは使用していません。

画面取得時の透過背景の問題と、アプリ終了待機が残る問題を修正し、修正後にローカル起動・停止と公開中の通常終了を再検証しました。

## 実行したチェック

- `bash scripts/build.sh`：Swift、Linux/arm64向けGo、initramfs生成、アプリ署名・署名検証に成功
- `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go vet ./...`：成功
- `python3 -m py_compile scripts/prepare.py tests/integration.py tests/ui_smoke.py`：成功
- `python3 tests/integration.py`：実VM、実公開、IP、隔離、通常停止、強制終了、スリープ通知の全チェックに成功
- `python3 tests/ui_smoke.py`：ネイティブUIのローカル起動・停止、公開中の通常終了に成功

実装途中で見つかったカーネル形式、devtmpfsの設定、URL発行直後のDNS未反映を修正し、実経路で再検証しています。DNS設定の変更やTLS検証の無効化は行っていません。

## ローカルの証跡

ソース管理には入れず、次の場所へ残しています。IPや内部設定を含むファイルは公開しないでください。

- `test-results/verification-20261015-053747/report.json`：実経路の検証結果
- 同ディレクトリ内の各セッション：VM出力、観測データ、隔離検査、公開ログ
- `test-results/ui-20261015-054236/report.json`：ネイティブUI検証結果
- 同ディレクトリ内のPNG：ローカル準備完了、停止、公開中の表示

強制終了したセッションのstate.jsonは、終了直前のactive=trueの記録が残ることがあります。強制終了後の状態はreport.jsonのプロセス回収・入口閉鎖・公開応答の検査結果で判定しています。全検証後にはVM実行プロセス、HoneyObs、cloudflaredの残存がないことも確認しました。

## 今回の範囲外

実スリープ、別回線の端末からの独立したアクセス、IPv6の送信元IP照合、第三者の自然流入、長時間・高負荷試験、VM基盤自体のセキュリティ監査は実施していません。今回の送信元試験は、このMacから公開Cloudflare経路へ送信したIPv4通信です。

初期成果物は約79 MBのローカル署名アプリでした。地図とGeoIPは後述のGUI工程で追加しました。長期保存、固定URL、配布用署名・公証は未実装です。Linuxの対応ソース提供を含む一般配布時の手続きも未完了です。

作業開始時のディレクトリは空でGitリポジトリも存在しなかったため、ローカルGitリポジトリと専用ブランチを作成しました。検証完了時点ではGitHubのリモートはなく、PRは作成していませんでした。その後、ユーザーの指定により、公開先を [tndd/HoneyObs](https://github.com/tndd/HoneyObs) としてoriginを設定しました。初回公開には検証済みの最小構成を使用し、未採用のアイコン候補は含めません。

## シアン監視室GUIの追加

同日、AppKit＋macOS同梱WKWebViewの画面へ置換し、実VMから受け取ったイベントを一覧・詳細・日本中心の地図に接続しました。採用した蜂蜜瓶のアイコンも組み込んでいます。GeoIPはDB-IP Lite 2026年10月版をアプリ内で検索します。

- 実アプリの公開ボタン→Quick Tunnel→POST /login→VMの受信IP→国照会→一覧・詳細・地図の経路を確認しました。
- 実アプリで過去と最新の行を選択し、詳細と経路の切り替えを確認しました。停止後に履歴を保持し、再開すると0件の新規セッションになることも確認しました。
- 1120×820と最小860×650のWKWebView画像を確認しました。最小サイズの下部情報は縦スクロールで表示します。
- Playwrightで、128件、長いパス、位置不明、確認用ラベル、選択中の新着、停止後の表示、HTML文字列の無害な表示、画面からのHTTP通信が0件であることを確認しました。
- Swiftで、同梱DBのIPv4/IPv6照会、IPv4-mapped IPv6、予約IP、合成した範囲の端点・隙間、欠損DB、UInt64イベントIDの文字列化を確認しました。

GeoIP試験中、GoogleのIPv6アドレスを米国と仮定した期待値が実データと一致しませんでした。固定したDBの該当範囲を独立して確認するとカナダだったため、期待値を同梱DBに合わせました。これは端末の実位置の確認ではありません。範囲検索の正否は別途、既知の合成データでも検査しています。

現在の画面検証はDOMボタンとWKWebViewスナップショットを用います。上記「初期の最小画面」のAppKit performClickとは検証方法が異なります。視覚確認の条件・意図した差分は [画面確認](design-qa.md) に記録しています。

GUI検証記録：`test-results/dashboard-20261015-161057/report.json`。国は推定、地図の点は国の代表位置です。日本の終点は表示上の基準であり、Macの位置を取得していません。実スリープ、別回線からの独立アクセス、自然流入、一般配布用の署名・公証は引き続き未検証です。

GUI追加後の回帰検証でも、ローカルVMの9種類の隔離プローブ、公開経路・IP照合・入力制限・通常停止、強制終了時のトンネル回収、スリープ通知ハンドラ、公開中のネイティブアプリ通常終了が合格しました。回帰記録は `test-results/verification-20261015-161057/` と `test-results/ui-20261015-161243/`、今回のアプリは約92 MiBです。

## 停止経路の優先修正（2026-10-15）

全体構成の改修を保留し、[実装戦略](safety-strategy.md)に沿って停止結果確認・終了待機・VM応答期限だけを先行しました。追加VM、launchd管理、通信先制限は製品に導入していません。

| 検証 | 結果・範囲 |
|---|---|
| ビルド・署名検査 | `bash scripts/build.sh` 合格 |
| 実VMの停止境界 | `bash tests/lifecycle.sh` 合格。起動直後OFFを3回、停止連打、停止APIの失敗・無応答、古い完了通知、観測応答コールバック喪失を検証。API境界への故障注入であり、カーネル故障の再現とは区別する |
| 修正前相当の検出 | 停止API失敗を無視して参照を外す変異を一時的なテスト用ソースに導入し、「停止API失敗を停止完了として扱った」でテストが失敗することを確認。製品ソースには適用していない |
| 実公開・既存の回帰 | `python3 tests/integration.py` 合格。ローカル隔離、実公開、IP、入力制限、通常停止、アプリ強制終了、スリープ通知ハンドラ。停止確認はactive=falseだけでなくshutdownComplete=trueを待つよう強化 |
| 実アプリの終了・監視役故障 | `python3 tests/stop_edges.py` 合格。終了時にVM停止を待ち、監視役SIGKILLでは回収未確認として再開を禁止する。監視役故障時の全回収を証明したとは扱わない。成否判定は試験用cleanupより前 |
| ネイティブUI | `python3 tests/ui_smoke.py` 合格。ローカル停止と公開中のアプリ終了後にshutdownCompleteとVM・トンネルの終了を確認 |
| 実受信から停止・再開 | `python3 tests/dashboard_smoke.py` 合格。実公開受信→地図・行選択→停止完了・履歴保持→ローカル再開→終了。取得した停止画面を目視確認 |
| ブラウザ画面 | `npm test` 合格。停止処理中・停止失敗では「停止未確認」と表示し、開始操作を無効化。画像で両状態を目視確認。従来の選択・不正HTML文字列・通信なし等の検証も合格 |

AppKitの終了待ちを初めにterminateLaterで実装したところ、実アプリの起動時終了試験で停止処理が進まず12秒で失敗しました。通常イベントループで回収してから再度終了する方法へ修正し、失敗した試験とネイティブの公開中終了を再実行して合格しました。

記録：

- `test-results/lifecycle-82DC498E-8636-47E4-8F8F-A60444858CDC/report.json`
- `test-results/lifecycle-mutation/report.json`
- `test-results/verification-20261015-213735/report.json`
- `test-results/verification-20261015-214431/stop-edges-report.json`
- `test-results/ui-20261015-214441/report.json`
- `test-results/dashboard-20261015-214617/report.json`
- `test-results/dashboard-browser/stopping.png`、`stop-failed.png`

試験後にHoneyObs、cloudflared、仮想化実行プロセスの残存がないことを確認しました。ネイティブGUI操作は既存のテスト入口からボタンの処理を呼ぶ方式です。Playwrightでのボタンクリックと、実VMを伴うネイティブWebKitの試験を分けて記録しており、OS全体を人が操作した検証ではありません。アプリ内組み込みブラウザは使っていません。

実スリープ、OSログアウト／シャットダウン、別端末・別回線からの独立アクセス、アプリ／監視役のフリーズからの完全回収、長時間高負荷、Mac側通信制限は今回の対象外または未検証です。#2〜#7の全体保証は未達であり、この先行修正でIssueを閉じません。

## localhost自己ペネで見つかった4件の修正（2026-10-15）

#9〜#13に対し、PR #8の停止修正とは別の差分で観測処理を修正しました。

- Host不一致は403イベント、HTTPパーサーの拒否は理由別件数・最終時刻として記録します。接続枠上限と中継上限はMac側で集計し、未解析要求に送信元IPやパスを推測で付けません。
- 外来パスの接頭辞で「確認用」に分類しません。内部の公開確認も通常の観測として扱います。
- VMとMacは各4096件を上限とし、イベントIDを追って128件ずつ取得します。取得前の欠落数と保存上限による破棄数は区別します。画面は従来どおり最新128件です。
- 長いEscapedPathは512バイト以内に切り詰め、エスケープ途中での切断を避けます。元の長さ・切り詰め有無・元のパスのSHA-256を記録／表示します。query/body/認証情報は保存しません。

`tests/self_pentest.py` は以前と同じ20入力ケース、160件・同時4接続、低速8接続による枠占有、第9接続の拒否、回復、接続を残した停止を再現します。試験用Engineの起動2箇所だけを置換し、製品Relay・実VM・製品観測取得を通します。外部トンネルは起動せず、127.0.0.1のLISTENとsupervisor不在も確認します。

改善確認の結果：

| 項目 | 修正前 | 修正後 |
|---|---|---|
| Host不一致 | 403だが記録なし | 403イベント1件 |
| 不正メソッド・Content-Length矛盾・巨大ヘッダー | 拒否されるが記録なし | HTTP 400が2件、431が1件の理由別集計 |
| 低速8接続と第9接続 | 拒否・回復するが集計なし | VM側で8接続の拒否、Mac側で接続数上限1件を集計し、回復 |
| 確認用ラベル | 攻撃者指定パスでtest=true | 同じパスでもtest=false、画面に確認用バッジなし |
| 短時間160件 | 160応答に対し取得前に32件消失 | 160件全件のパスを保存、取得前欠落0件 |
| 長いパス2種 | 512バイトへ同じ文字列として省略 | 元522バイト・省略フラグ・異なるSHA-256を保存／表示 |

最初の再試験では、低速接続がHTTP未完了として集計されるという期待値と、実VMのHTTP処理が400へ変換する挙動が一致せず失敗しました。取得できた読取期限エラーは区別し、その他は観測できたHTTP 400として記録します。試験は低速入力前の400が2件であることと、その後の400／期限／未完了の増分が8件であることを照合し直し、同じ攻撃で合格しました。HTTP 400をすべて形式不正と断定しない表示にしています。

検証：

- `bash scripts/build.sh`：ビルド・署名検査合格。
- `cd guest && go test -race observation.go observation_test.go`：実HTTPパーサーの拒否・Host拒否、5000件から4096件への保持、ページ境界、パス省略・識別・秘密情報非保存、競合検査が合格。
- `swiftc Sources/HoneyObs/{ObservationStore,ObservedEvent,GeoIP}.swift tests/ObservationChecks.swift -o /tmp/honeyobs-observation-checks && /tmp/honeyobs-observation-checks`：5000件の分割取得・904件の保存上限破棄、32件の取得前欠落、重複ページ拒否が合格。
- `python3 tests/self_pentest.py`：上記20ケースと負荷・回復・停止が合格。`test-results/self-pentest-20261015-222558-366009/report.json`。
- `node tests/self_pentest_ui.cjs test-results/self-pentest-20261015-222558-366009`：実ログを用いた製品画面の行選択・省略表示・拒否集計・偽装ラベルなし・XSS非実行・外部通信なしを確認。上限超過表示にはストア境界試験に対応する合成状態を使用。1120pxと860pxの画像を目視確認。
- `npm test`：既存画面回帰に合格。
- `bash tests/lifecycle.sh`：実VM停止境界の回帰に合格。`test-results/lifecycle-C5B0B3D5-31CE-4E17-BD5C-779E2A25A6A6/report.json`。
- `python3 tests/integration.py --local`：ローカルVM隔離回帰に合格。`test-results/verification-20261015-222247/report.json`。

初回自己ペネの記録 `test-results/self-pentest-20261015-01/` と比較しています。今回の試験は外部経路を含まず、Cloudflareによる拒否・ヘッダー上書きは未検証です。GUIは実ログのPlaywright描画で、ネイティブWebKitの全操作を再試験したものではありません。アプリ内組み込みブラウザは使用していません。永続的な監査ログ、全攻撃への耐性、停止直前にVMに残る未取得記録の回収は保証対象外です。


## 自己ペネの実GUI表示と右下シールド（2026-10-15、#15）

`python3 tests/self_pentest.py --gui` で、実VMへの試験と製品Dashboardを同時に動かします。試験用Engineは従来と同じ起動2箇所の置換だけで、HTTP処理・中継・観測処理は変更していません。進行ファイルには試験名・HTTP結果・記録数だけを渡し、応答受信と記録確認を別の段階で表示します。GUIの受信件数と実ログ、HTTP 403通知とHTTP解析前拒否通知も照合します。

シールドは地図右下に幅216pxで置き、短い900msの通知動作だけを行います。操作を遮らず、動きを減らす設定に従います。受信・認証失敗・拒否を実測に応じて区別し、404を防御成功と解釈しません。localhost試験ではIPヘッダー偽装を地理情報に変換しません。

検証結果：

- `bash scripts/build.sh`：署名を含めビルド成功。
- `npm test`、`node tests/live_dashboard.cjs`：従来の画面に加え、応答と記録の分離、右下の配置、行選択、中止、停止後の再公開禁止、860px表示、動き軽減、外部通信なしを確認。Playwrightの画像を目視確認。
- `python3 tests/self_pentest.py --gui --close-after`：20ケース・160件の連続送信・接続数制限・回復・停止が合格。実WKWebViewで22回の進行照合が合格し、ネイティブ画像のHTTP 403とログ表示を目視確認。記録：`test-results/self-pentest-20261015-230529-f11289/report.json`。
- `python3 tests/live_pentest_cancel.py`：試験の最初のケース中に実WKWebViewの中止ボタン処理を呼び、試験側中断・Runner終了・VMなし・停止確認済み・localhost入口閉鎖を確認。記録：`test-results/self-pentest-20261015-231031-7f74d3/report.json`。

ネイティブ操作はWKWebView内のボタン処理を呼ぶ方式で、クリック自体は別途Playwrightで確認しています。アプリ内組み込みブラウザは使用していません。外部トンネル経路は今回の対象外です。ゲストや停止本体に変更がないため、全隔離プローブや停止API故障注入の全体再実行は省略し、この変更に関係する実VM自己ペネとGUI中止を検証しました。全攻撃への耐性や、停止直前にVMに残った未取得記録の回収を保証するものではありません。

最終の画面を残す実演：`test-results/self-pentest-20261015-231357-af7f66/report.json`。同じ全ケースと22回のGUI照合を再確認し、停止済みの結果画面だけを保持します。完了後は進行監視タイマーを停止するため、画面を残しても検証状態の定期書き込みは継続しません。試験Runnerを独立したセッションで起動し、呼び出し元の終了後にも結果を閲覧できるようにしています。


## 通常アプリとしての導入と組み込み自己ペネ（2026-10-17、#17）

`~/Applications/HoneyObs.app` に採用アイコンとすべての実行資産を同梱して導入しました。以前の単体Runnerには通常アプリのアイコンと起動導線がありませんでした。製品画面の「自己ペネ」からSwift製の固定localhost試験を起動でき、実行時にPythonやrepoは不要です。Engineのlocalhost専用モードを使い、任意宛先・任意要求を入力する機能はありません。

`bash scripts/build.sh`、`bash scripts/install.sh`、`python3 tests/installed_app.py`、既存の `npm test` と拡張した `node tests/live_dashboard.cjs` が合格しました。導入済みコピーを `/tmp` からLaunch Servicesで起動し、実行パス、repoファイル非参照、バンドル資産利用、アイコン、署名、20ケース・160件全件記録・低速8接続の拒否・第9接続拒否・回復・VMと入口停止を確認しました。製品WKWebViewからの中止、860px表示、完了画像と中止画像の目視確認も実施しました。記録は `test-results/installed-app-20261017-005119/report.json` です。独立した既存試験 `python3 tests/self_pentest.py --gui --close-after` も合格し、`test-results/self-pentest-20261017-005119-77055e/report.json` に保存しました。

今回、公開経路自体と停止APIは変更していないため、外部公開の再試験や停止API故障注入の全体再実行は省略しました。Developer ID署名・公証や一般配布向けインストーラーは含みません。このMac向けのローカル署名です。


## フリーズ時の転送失効（2026-10-17、#19）

画面の一回限りの確認応答、VMの新しい応答、メイン処理とwatchdogの専用パイプを用いる3秒の許可を追加しました。Relayは100ms周期の独立検査と各転送境界で失効を確認します。古い応答を延命せず、SIGCONTでも失効した許可を復活させません。設計と残る回収限界は `safety-strategy.md` に記載しています。

検証済み：

- `bash scripts/build.sh`、`npm test`、`node tests/live_dashboard.cjs`：ビルド・署名と従来画面が合格。
- `tests/PermitChecks.swift`：上流の古い時刻から延命しない、期限境界、期限切れ／OFF後の更新不可、別許可との分離を確認。失効後の更新を許す試験用変異では失敗を検出（`test-results/permit-mutation/failure.log`）。製品ソースは変異させていません。
- `python3 tests/permit_faults.py`：導入済み.appと実VMの本文送信途中で、主スレッド5秒停止とGUIのJS無限ループを注入。クライアント接続は実測2.468秒／3.041秒で閉鎖し、失効後に投入した新規要求へも応答せず、通常ループ復帰後のVM・入口停止を確認。
- 同試験で、トンネル資産だけを通信しない固定子プロセスへ置換した署名済みバンドルを使用。親SIGSTOP中の子の終了は2.481秒、watchdogのSIGSTOP中の公開入口閉鎖は2.447秒。観測前にcleanupせず、SIGCONT後のVM・watchdog・子の全終了と再開不可を確認。旧許可フレームの再送も拒否し、子のwait完了を確認。記録：`test-results/permit-faults-20261017-010656/report.json`。
- `python3 tests/installed_app.py`：期限導入後の正常20ケース／160件／低速接続／回復・停止と、GUI中止・repo非参照が合格。`test-results/installed-app-20261017-010612/report.json`。中止画面を目視確認。実行中の導入済み.appのNSRunningApplicationからアイコンも取得・目視確認。
- 独立した既存 `python3 tests/self_pentest.py --gui --close-after`：全ケースとGUI22回照合が合格（`test-results/self-pentest-20261017-010036-43fb71/report.json`）。
- `bash tests/lifecycle.sh` と `python3 tests/integration.py --local`：起動中停止・API失敗・無応答・遅着・ゲスト応答喪失、および実VMの既存隔離プローブが合格。`test-results/lifecycle-79D91007-2D1C-4656-8BD3-4F6429988A6C/`、`test-results/verification-20261017-010046/`。

途中、既存接続の試験でHTTP 400を受信して失敗しました。送った不完全ヘッダーに対するゲスト側の2秒の拒否であり、3秒の許可期限前の応答でした。本文読取りを継続する要求に変更し、期限切れ前に応答したヘッダー拒否を「期限切れ後の転送」と混同せず検証し直しました。また、GUI中止と送信が競合してHTTP 0を失敗表示する不具合を見つけ、ユーザーの中止として記録・表示するよう修正し、失敗した導入済みアプリ試験を再実行して合格しました。

試験専用の `--ui-exercise-smoke` 指定時には700の私有ディレクトリ内だけにHost確認値を保存して、本文送信途中の試験に使います。通常起動ではこの出力を行いません。要求とHost値をGUI進行や共有レポートへ渡しません。

この段階では外部公開を行っていません。Cloudflare実経路、実スリープ、OS停止、watchdog自体のSIGKILL後に残る子のOS所有・全回収は今回の合格範囲へ含めません。テストの最後のcleanupは成否判定とは別です。#2〜#7の全体課題は継続します。

最終確認では、IP偽装ケースまで進めて中止し、通常画面へ戻った際もローカル試験として扱う操作を追加しました。試験パネルを閉じると申告IPを地理推定へ戻してしまう箇所を修正し、セッションが変わるまでは試験の印を維持します。通常完了・送信中の中止・IP偽装後の中止と通常画面復帰の3経路を、導入済みアプリで検証して合格しました（`test-results/installed-app-20261017-011149/report.json`）。画面復帰後は選択経路と背景経路の双方が0であることも追加で確認して合格しました（`test-results/installed-app-20261017-011355/report.json`）。停止中は確認値を発行せず、同一内容の画面更新を継続しないようにしています。
