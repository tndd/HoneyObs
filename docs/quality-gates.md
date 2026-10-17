# 品質ゲートと検証専用操作

## 自動CI

PRとmainへのpushでは次の3ジョブを実行します。必要な権限はリポジトリの読み取りだけです。

| ジョブ | 検査する範囲 | 証明しない範囲 |
| --- | --- | --- |
| ゲスト | Ubuntuで観測VMのGo module全体の `go test -race -count=1 ./...`、通信VMのLinux ARM64ビルド | Apple Virtualization.frameworkでの実行、Mac側の経路、通信VMの実seccomp |
| 画面 | 固定fixtureでPlaywright、行選択、外来文字列、保持上限、外部通信なし | 実WKWebView、実VM、実ログとの照合 |
| Swift・導入 | 製品ObservationStoreと転送許可、LaunchOptions、導入/更新/失敗復旧の署名済みfixture、製品Swift全体の型検査、ビルドしたバンドルのブランド資産・ライセンス・開発署名 | VM生成、実導入済みアプリ、物理操作 |

Swift検査は `bash tests/unit.sh` で再現できます。導入fixtureは一時ディレクトリだけを使い、Launch Services登録をfixtureへ置き換えます。ユーザーのアプリと登録DBは変更しません。

開発バンドルは `build/Applications.noindex/HoneyObs.app`、QAコピーは各 `test-results` 内の `Applications.noindex/HoneyObs.app` にだけ生成します。導入fixtureの一時親も `.noindex` にします。`qa_registry_checks.py` はコピー前の保存先、symlink・別tree・通常の親・別IDの拒否と、登録後のID差替え拒否を検査します。製品IDとsession-jobs専用fixture IDの登録解除は、起動したそのパスだけを対象に成功記録の前に確認します。Spotlightの索引除外とLaunch Services登録解除は別の境界です。以前の索引や残存コピーの回収はこのfixture検査では証明しません。

画面ジョブでは `tests/live_dashboard.cjs` も実行し、固定状態で右下シールド・応答と記録の分離・中止・完了後の復帰・縮小画面・動き軽減を確認します。

## 実Macの別ゲート

`bash scripts/local_vm_gate.sh` はApple Siliconの実Macで明示実行します。CIからはworkflow_dispatchの `local_vm` を選び、`self-hosted, macOS, ARM64, honeyobs-vm` の専用ラベルを持つrunnerだけへ送ります。通常のPR検証では実行しません。

同一Mac内では `${TMPDIR}/HoneyObs-real-mac-qa.lock` をmkdirで排他取得します。ロックが残った場合は記載PIDのフルコマンドと検証対象を確認し、実行が終わっていると確定してから残存ロックを回収します。進行中の検証を自動で強制終了しません。

このゲートは作業tree内にビルドした `.app` を使い、localhostの隔離検査、ライフサイクル、独立したPython自己ペネを実行します。`~/Applications` の置換、公開トンネル、実スリープ、ログアウト、シャットダウンは含みません。self-hosted runnerは検証専用とし、通常利用するMacに無断で登録しません。

`python3 tests/egress_privileges.py` は同じ製品Goソースを専用Linux test binaryにし、NIC・共有・ディスクなしの私有VMで実行します。権限縮小とseccomp設定を意図的に別OS threadへ置き、UID65533・能力なし・NNP1・Seccomp2・IPv6 socket拒否を、既存thread・新thread・exec後に照合します。通信VM launcherのビルドは `CGO_ENABLED=0` が必須です。NNPの全thread同期がcgoの外部threadを検査できないためで、ビルドスクリプトで固定しています。同期不能やseccomp TSYNCの失敗threadIDは起動失敗として扱います。

`tests/installed_app.py` は導入済みアプリを対象にする別検証です。専用ゲートに自動混入させません。`tests/permit_faults.py` は現行buildの署名済み私有コピーとlocalhostを用い、mainの5秒停止・JS無限ループ、期限後HTTP拒否、VM回収と非復活を確認し、専用ゲートにも含めます。

実アプリを起動するPython検査は `tests/qa_registry.py` にそのアプリだけを記録し、全caseの稼働・回収判定後、成功reportとPASS表示より前に `lsregister -u` の成功を明示確認します。失敗は非zeroへ伝播し、atexitでは失敗・中断時の残りだけを再試行します。専用ゲートのEXITはゲート排他だけを解除し、子が解除済みのアプリを二重に解除しません。この作業treeのbuild/test-results内のHoneyObs以外、導入済みアプリ、別worktree、symlinkは受け付けず、登録一覧の探索や一括解除はしません。検査中のプロセスやVMをこの処理で終了させることもありません。

## 製品と検証の境界

`--headless`、`--public`、`--ui-*` の検証用起動には `--test-mode --run-directory /絶対パス` が必要です。保存先は現在の利用者が所有する0700の実ディレクトリに限定します。シンボリックリンク、相対パス、複数の保存先、共有可能なディレクトリを拒否します。

通常起動では `HONEYOBS_PROBE_TARGETS` を採用せず、`command` と `ui-command` を操作入力として読みません。owner/clientが引き継ぐ内部保存先は検証モードを有効化しません。起動オプションのpure検査と、製品App/Engineへ渡す境界の実機検査を区別します。

独立Python自己ペネは製品EngineのlocalExerciseを直接リンクした専用Runnerを使います。起動処理のソース置換は行いません。UIのfixture、独立したHTTP/ログ突合、通常アプリの内蔵自己ペネは別々の証拠として記録します。

## 普段のMacアプリとしての挙動

通常終了、ウィンドウを閉じる操作、利用者切替、画面ロック、最小化、他アプリへの切替は別条件です。最小化や他アプリへの切替だけでアプリの終了を要求しません。ウィンドウを閉じた際はアプリの終了経路からVMと入口の回収を待ちます。画面ロックはスリープ通知の代用にしません。

転送にはVMと画面の新しい応答による3秒の許可が必要です。バックグラウンド・最小化・ロック中にWebKitの応答が抑制された場合は許可が失効し、安全停止する可能性があります。背景での継続公開を保証するには、各条件で許可の時刻、応答、接続閉鎖、最終のVM回収を実機で別々に確認する必要があります。

これらの物理操作は共有ユーザーセッションに影響するため、調整した検証枠で実施します。ウィンドウ最小化、別アプリへの切替、画面ロック、解除後の表示、再開操作を記録します。実スリープ・電源断・ログアウトをこの記録に含めていない場合、そのgateは未検証です。

## 結果の扱い

CI定義の追加とGitHub上の実行成功は別です。ローカル検証、CI、実MacのVM、製品GUI、導入済みアプリ、実スリープ、公開経路をそれぞれ報告します。停止要求・プロセス終了・VM回収・公開停止を一つの成功状態へまとめません。ローカル証跡は `test-results/`、CI画面失敗時の画像は7日間のartifactに保存します。IPを含む実VMログを自動で公開artifactへアップロードしません。

## 二台VMと故障注入の追加ゲート

`tests/egress.sh --vm` は通信VM単体の禁止操作・固定API・TLS検査・起動途中停止を、`tests/egress_engine.sh` は製品Engineから両実VMをつなぐlocalhost fake edgeを検証します。実Cloudflare API・TLSの成功は証明しません。

`tests/session_jobs.py` はVMなしの実launchd相互回収を検証します。`tests/session_ownership.py --egress-fixture` は `EGRESS_TESTING` の専用アプリに対し、UI・監視役・各VM補助プロセスのSIGKILL/SIGSTOPを外部から観測します。後処理で終了させたものを製品の回収成功に数えません。各試験は同じ実行先を上書きせず、署名した私有アプリコピーを使います。

`tests/app_background.py` は通常GUIの自ウィンドウだけを最小化・非表示にします。開始前にOSのセッション状態を読み、画面ロック中・コンソール以外・取得不能なら理由をreportへ記録し、App/VMを起動せず非zeroで中断します。解除後は同じ検査を再実行し、未完走をPASSへ読み替えません。追加のJSによる状態注入をせず、ネイティブのfreshness、HTTP応答、OSが持つUUID付きVM helperを突き合わせます。他アプリ・画面ロック・実スリープを操作しません。

`tests/menu_integration.py` は私有コピーの実WKWebView・観測VMでNSMenuを4.2秒保持し、実tracking mode内でUI/guest時刻と有効permitが進み、既存の所有PID/誕生identity・両jobを維持したまま追跡中と終了後のlocalhost HTTPが応答することを確認します。メニュー開始は元TimerとGCD main blockを抜けてから行い、終了後は実VM helperと所有processの消滅・QA登録解除を成功記録の前に確認します。

新しい最終観測・保存排他・ログ上限の検査は `tests/unit.sh`、URLの分割とログ回転は `tests/console_capture.sh` に含めます。一般配布の署名ゲートは `python3 scripts/check_bundle.py --distribution` で明示し、Developer IDを用意できない現在の環境ではBLOCKEDとします。
