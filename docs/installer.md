# バージョンを指定してコマンド1行でインストール

[インストールと機能](../README.md) · [技術資料一覧](README.md)

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

基本の操作は[READMEのオンラインインストール](../README.md)にまとめています。このページでは版の選択、完了確認、自動起動の指定、復旧と配布方法を説明します。

ルーターがインターネットへHTTPS接続できれば、PCで本体ファイルをダウンロードして転送する操作を省略できます。**バージョンごとのインストーラーが、指定された版の`rtx-dns.lua`だけを取得します。** SHA256を照合してから`/lua/rtx-dns.lua`を起動します。

最新版の検索は行いません。後から別のReleaseが公開されても、同じインストーラーが取得する版は変わりません。現在の版を確認してから、導入するバージョンを選んでください。

## 実行方法

2026年9月25日時点の公開区分は次のとおりです。**v0.9.9を導入するには、v0.9.9用のコマンドを選びます。** 既存環境で実行した場合も、選んだ版へ置き換わります。

| 導入する版 | 公開区分 | インストーラーの配布ファイル |
|---|---|---|
| [v0.1.4](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.4) | 安定版 | [rtx-dns-install-v0.1.4.lua](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/v0.1.4/rtx-dns-install-v0.1.4.lua) |
| [v0.9.9](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.9.9) | Pre-release | [rtx-dns-install-v0.9.9.lua](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/v0.9.9/rtx-dns-install-v0.9.9.lua) |

YAMAHAルーターの**管理者コンソール**または[WebGUIのコマンド実行画面](#webgui)で、選んだ版の1行だけを実行します。先頭の`yes`は自動起動の指定です。自動起動を追加せずにインストールする場合は、この`yes`だけを`no`へ変更します。

このコマンドは、固定したcommitからインストーラーを取得し、HTTP応答とサイズを確認してメモリ上で実行します。インストーラーの版確認・重複実行の検出・本体のSHA256照合などは、取得したインストーラーが行います。`/lua`がなくても、設定・実行状態と本体の検証を済ませてから自動で作成します。インストーラー自身はファイルへ保存しないため、既存の`/lua/rtx-dns-install.lua`がある場合も上書き・削除しません。

<a id="version-v014"></a>

### v0.1.4をインストール

<!-- INSTALLER_COMMAND_V014_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/bd9762874861d7e0e71b9dcdeba3cfc0c1a4843e/installer/versions/v0.1.4/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==25773,"Installer download failed");assert(loadstring(r.body))(DNSINSTALL_BOOT,"v0.1.4")'
```
<!-- INSTALLER_COMMAND_V014_END -->

<a id="version-v099"></a>

### v0.9.9をインストール

<!-- INSTALLER_COMMAND_V099_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/bd9762874861d7e0e71b9dcdeba3cfc0c1a4843e/installer/versions/v0.9.9/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==25773,"Installer download failed");assert(loadstring(r.body))(DNSINSTALL_BOOT,"v0.9.9")'
```
<!-- INSTALLER_COMMAND_V099_END -->

- `yes`：起動確認後に自動起動を登録し、`save`で現在のルーター設定全体を保存します。他の未保存の設定変更も保存されます。
- `no`：インストーラー自身は自動起動設定と保存済みconfigを変更しません。すでにある自動起動設定は維持します。ただし、WebGUIのコマンド実行画面では、画面側の機能で現在のルーター設定が自動保存されます。

画面に`DNSINSTALL (16/16) Installation complete`が出れば、インストールは終了しています。続いて表示される案内に従って**Enterキーを押すと、ルーターのコマンドプロンプトを再表示できます。** たとえばv0.9.9では、最後に次の2行を表示します。

```text
DNSINSTALL (16/16) Installation complete: v0.9.9.
DNSINSTALL Press ENTER to display the router command prompt.
```

ログのカウンターは、途中経過・結果を含めて表示するたびに1つ進みます。現在のv0.1.4・v0.9.9は`(1/16)`から始まり、`(16/16) Installation complete`で完了します。新規導入・同じ版の再導入・`yes`/`no`の指定によって母数は変わりません。最後のEnter案内には番号を付けません。所要時間の割合を示すものではありません。

`lua`コマンドは処理中でもコンソールのプロンプトを返します。表示が混ざりにくいよう、インストーラーは最初の進捗表示前に1秒待機して改行します。プロンプトが表示されても処理は続いているため、上の完了表示を待ってください。`Installation complete`まで表示されたことを確認してください。完了後はインストーラーがEnter入力を待っているわけではありません。同じコマンドを重ねて実行する必要はありません。

既存の`/lua/rtx-dns.lua`と内容が同じなら、本体ファイルの上書きは省略します。ディスク上のファイルと稼働中の版が異なる場合もあるため、対象タスクは停止・再起動し、確認したファイルと現在のDNS設定を読み込みます。設定変更だけなら、ダウンロードを伴わない通常の[スクリプト再起動手順](install.md#update-script)も使用できます。

<a id="webgui"></a>

### WebGUIからインストールする場合

**「管理」→「保守」→「コマンドの実行」**を開き、上記の導入する版の1行コマンドを貼り付けて実行します。RTX1210 Rev.14.01.42で、公開済みのv0.9.9用コマンドによる導入とDNS応答を確認しました。

**WebGUIの「成功」はコマンドの受け付けを示し、インストール完了を示すものではありません。** Luaは背後で処理を続けます。進捗や完了のメッセージはコマンド実行ログに表示されないため、1分程度待ってから、同じ画面で次のコマンドを実行してください。実機試験では約46秒で完了しましたが、通信状況などにより時間は変わります。

```text
show status lua
```

次の2点を確認します。長い出力が読みにくい場合は、画面の**「テキストファイルで取得」**を使えます。

- 実行履歴で、今回のインストールコマンドの開始・終了日時を確認し、走行結果が`正常終了`になっていること。以前の実行履歴と取り違えないようにしてください。
- 実行中の一覧に`/lua/rtx-dns.lua`が1件あり、開始日時が今回のインストールに対応していること。

インストーラーがまだ実行中なら、しばらく待ってから確認し直します。WebGUIでは最後のEnterキーの案内に対応する操作は不要です。この画面はコマンド実行時に現在のルーター設定を自動保存するため、`no`を指定しても、他の未保存の設定変更が保存されます。

### インストーラーを手動で転送する場合

上の表から導入する版のインストーラーをダウンロードし、USBメモリ等でルーターの**`/lua/rtx-dns-install.lua`**へ保存します。配布ファイル名には版番号がありますが、ルーター上ではこの共通の一時ファイル名に変更して使用してください。

```text
lua /lua/rtx-dns-install.lua yes
```

開始時の引数には`yes`か`no`を必ず指定します。本体のSHA256照合や起動確認などは、上の1行コマンドと共通です。この方法でも、本体の取得にはルーターからのHTTPS接続が必要です。

手動転送したインストーラーは、成功時に作業ファイルとともに自身を削除します。この場合の完了表示は`DNSINSTALL (16/16) Installation complete: v0.9.9; installer removed.`のようになります。失敗した場合はインストーラーを残します。

## 自動で行う処理

1. インストーラーに組み込んだ版番号・本体のサイズ・SHA256・取得URLと、ルーターの設定・実行状態を確認します。
2. その版の本体を、固定したcommitのHTTPS URLから1回取得し、サイズを確認します。Latestや別のmanifestは参照しません。
3. SHA256・Lua構文を確認します。この段階では現行DNSを停止しません。
4. `/lua`がなければ作成し、本体を作業ファイルへ書き込んで読み戻しを確認します。旧ファイルと以前の実行状態を復旧用に保存します。
5. 対象のDNSスクリプトだけを停止します。
6. 本体ファイルを差し替え、対象のDNSスクリプトを起動します。内容が同じ場合はファイルの差し替えを省略します。
7. 実行状態を複数回確認します。起動に失敗した場合は旧ファイルと以前の実行状態へ戻します。
8. `yes`の場合は、既存の同一スケジュールを使うか、1～999の範囲で空いている最小の番号を選び、保存します。`no`の場合は、インストーラー自身は自動起動設定と保存済みconfigを変更せず維持します。WebGUI側の自動保存については[WebGUIの手順](#webgui)を参照してください。
9. 成功時に作業ファイルを削除し、完了とEnterキーの案内を表示します。手動転送したインストーラーを実行した場合だけ、インストーラー自身も削除します。

スケジュールの検索範囲はインストーラーの実装上の範囲です。別のスクリプトや他のスケジュールは変更しません。別の保存場所・独自の起動設定・NVR試験版からの移行には[通常の手順](install.md)を使用してください。

起動確認は対象Luaタスクが継続して実行されていることの確認です。導入後は利用する端末から`dig @ルーターのIPアドレス microsoft.com TXT +time=5 +tries=1`などで名前解決も確認できます。

## HTTPSでの配布方法

Releaseの配布先では署名付きの長いURLが使われます。RTX1210のHTTP APIで、そのURLが再エンコードされ署名検証に失敗する現象を確認したため、ルーターからの取得には短い`raw.githubusercontent.com`のHTTPS URLを使用します。

[`installer/versions/`](../installer/versions/)には、版ごとにReleaseの本体と`SHA256SUMS`のコピーを置きます。インストーラーは公開時に確認した本体のサイズ・SHA256を持ち、本体の取得先も40文字のcommit IDと版番号を含むURLに固定します。コマンド1行で取得するインストーラー自身のURLも、公開済みのcommitへ固定します。版を選び直すときは、その版のコマンドまたは配布ファイルを使用してください。

従来の「最新安定版を自動選択する」配布方法は終了しました。以前のコマンドは旧配布先を取得できず、現行DNSを停止する前に終了します。上記のバージョン別コマンドへ置き換えてください。

HTTPS対応のファームウェアとGitHubへ到達できるDNS・通信設定が必要です。HTTPSが利用できない環境では、インストーラーを使わずに[本体をUSBメモリ等で転送する手順](install.md)を使用してください。

短縮したメモリ実行コマンドは、RTX1210 Rev.14.01.42でv0.1.4の導入、9段階の表示、DNS応答、設定の維持を確認しました。表示修正後のv0.9.9も、試験用LANからインストーラーを読み込んで同じ項目を確認しました。[短縮コマンドの試験結果](results/short-bootstrap-2026-09-25.md)を参照してください。

インストーラーをファイルへ保存する方式では、RTX1210 Rev.14.01.42でv0.1.4・v0.9.9の導入、DNS応答、不正な本体の拒否を確認しました。[試験項目と結果](results/versioned-installer-2026-09-25.md)を参照してください。従来の最新版選択方式の実機結果は[過去の検証記録](results/installer-2026-09-25.md)として残しています。

## 途中で失敗した場合

途中で失敗した場合は、進捗カウンターを止めて`DNSINSTALL failed at stage n`を表示します。`n`は「自動で行う処理」の1～9の工程番号です。エラーと自動復旧・後始末のログには進捗カウンターを付けません。起動失敗時の自動復旧が成功した場合は、`previous file and running state restored`も表示します。

1行コマンドの場合は、原因を修正してから同じ1行を再実行してください。インストーラーの取得や読み込みに失敗した場合は、工程番号のないLuaエラーが出ることもあります。手動転送した場合は、失敗時に残った`/lua/rtx-dns-install.lua`を`yes`または`no`付きで再実行できます。どちらの場合も、残った作業ファイルがあるときは下記の確認と復旧を先に行ってください。

電源断などで作業ファイルが残った場合は、自動で上書きせず停止します。`show file list /lua`と`show status lua running`で状態を確認してください。

| ファイル | 用途 |
|---|---|
| `rtx-dns.install-old` | 差し替え前のファイル。復旧確認が済むまで保持します。 |
| `rtx-dns.install-new` | 照合済みの書き込み候補。 |
| `rtx-dns.install-state` | 対象版・SHA256・旧ファイルや実行状態の記録。 |

旧版へ手動で戻す場合は、対象スクリプトを停止して停止を確認し、`rtx-dns.install-old`を`rtx-dns.lua`へコピーしてから起動します。正常動作を確認してから残った作業ファイルを削除してください。`save`の応答が不明な場合は、確認済みの本体を保持するため、自動で旧版へ戻しません。自動起動設定と保存結果を確認してください。

## 配布を作成する開発者向け手順

本体のReleaseを公開した後、版を明示して配布ファイルを取得・照合します。Pre-releaseを対象にする場合だけ`--allow-prerelease`を付けます。

```sh
python3 tools/prepare_version_installer.py --version v0.1.4
python3 tools/prepare_version_installer.py --version v0.9.9 --allow-prerelease
```

生成された`installer/versions/<版番号>/`の本体・チェックサム・メタデータを確認してcommitします。その40文字のcommit IDを使って、対象版のインストーラーを生成します。

```sh
python3 tools/build_installer.py --version v0.1.4 --payload-ref <本体を含むcommitの40文字ID>
```

試験を行い、生成されたインストーラーをcommitします。そのcommit IDを使って公開用コマンドを生成します。

```sh
python3 tools/installer_command.py --version v0.1.4 --ref <インストーラーを含むcommitの40文字ID> --mode yes
```

対象Releaseへ`rtx-dns-install-<版番号>.lua`を追加し、このページの該当コマンドと試験記録を更新します。v0.9.9など別の版も、それぞれの版番号で同じ手順を行います。新しいReleaseの公開だけでは、既存のバージョン別インストーラーの取得対象は変わりません。

## アンインストール

削除する場合は、[アンインストール手順](uninstall.md)を参照してください。WebGUIから実行する方法も説明しています。
