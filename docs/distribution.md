# 導入・更新・復旧と配布の条件

## このMacへの開発用導入

`bash scripts/build.sh` で署名済みバンドルを作り、HoneyObsを終了してから `bash scripts/install.sh` を実行します。既定の導入先は `~/Applications/HoneyObs.app` です。引数で別の導入先ディレクトリを指定できます。実行利用者にSwift、Go、Python、Node.jsを要求する方式ではありません。

導入は同じファイルシステム上の一時領域へコピーし、元とコピー先の署名を検証してから置換します。導入先も検証し、Launch Servicesへ登録できた時点で完了とします。起動中の実行ファイル、導入先と旧版のシンボリックリンクは置換しません。

導入先の `.HoneyObs-install.lock` をmkdirで排他取得し、同時の導入・復元を拒否します。強制終了後にロックが残った場合は、別の導入処理が動いていないことを確認してから空のロックディレクトリを削除します。

更新前のバンドルは同じ導入先の `.HoneyObs-previous.app` へ保持します。次のコマンドで、現在版と直前版を交換できます。

```sh
bash scripts/install.sh --rollback
# 別の導入先の場合
bash scripts/install.sh --rollback '/別の導入先'
```

途中のコピー、置換、署名検査、登録、旧版保持に失敗した場合は元のアプリと既存の旧版を復元します。自動復旧も失敗した場合は旧バンドルを削除せず、一時領域のパスをエラー出力します。アプリと関連プロセスを確認してから、その場所の `previous.app` を元の導入先へ戻して署名を検証します。`prior-backup.app` がある場合はさらに前の版です。SIGKILLや電源断ではシェルの復旧処理を実行できないため、残存した `.HoneyObs-install.*` も調査対象にします。

この復元はアプリバンドルだけです。Application Support内の観測記録を削除・巻き戻しません。直前版は1つだけ保持し、古い版を無期限に保存する方式ではありません。

## 一般配布の未完了条件

`python3 scripts/check_bundle.py` はバンドルID・採用アイコン・同梱VM/GeoIP/画面/ライセンスとVirtualization entitlement・署名を検査します。開発署名でもbaselineは成功できます。`--distribution` を付けるとDeveloper ID Application署名、公証staple、Gatekeeperの成功を追加要求し、未完了なら終了コード1でblockerを報告します。この署名ゲートだけでは対応ソース提供・実配布先起動を証明しません。

2026-10-17のread-only検査では、導入済みバンドルはad-hoc署名でTeamIdentifierがなく、Keychainの有効署名IDは別アプリ用のローカル署名だけでした。Developer ID署名・公証・一般配布用Gatekeeper経路を完了したとは扱いません。確認した環境の状態であり、後から署名資格を追加した場合は再確認します。

一般配布前に、提供者が使用できるDeveloper ID Application証明書と署名用Keychain、公証資格、hardened runtimeの設定と必要なentitlementを用意します。その署名で同梱実行ファイルとアプリを署名し、公証の成功・staple・クリーンな配布先での起動を確認します。ローカルの `codesign --verify --deep --strict` 成功だけでは公証と配布先起動を証明しません。

LinuxのGPL対応ソースと使用ビルド定義を、配布物のバージョンに対応付けて実際に提供する方法も必要です。`third_party/README.md` の出典・原文同梱はこの準備の一部であり、ソース提供まで済んだとは扱いません。DB-IP CC BY 4.0の帰属表示と加工内容、他の同梱物のライセンスも配布物で確認します。

更新は現状、利用者がアプリを終了して行うローカル置換です。自動更新サービス、公開ダウンロード、Apple Developer登録の代行は追加していません。
