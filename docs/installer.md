# バージョンを指定してコマンド1行でインストール

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

ルーターがインターネットへHTTPS接続できれば、PCで本体ファイルをダウンロードして転送する操作を省略できます。**バージョンごとのインストーラーが、指定された版の`rtx-dns.lua`だけを取得します。** SHA256を照合してから`/lua/rtx-dns.lua`を起動します。

最新版の検索は行いません。後から別のReleaseが公開されても、同じインストーラーが取得する版は変わりません。現在の版を確認してから、導入するバージョンを選んでください。

## 実行方法

2026年9月25日時点の公開区分は次のとおりです。**v0.9.9を導入するには、v0.9.9用のコマンドを選びます。** 既存環境で実行した場合も、選んだ版へ置き換わります。

| 導入する版 | 公開区分 | インストーラーの配布ファイル |
|---|---|---|
| [v0.1.4](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.4) | 安定版 | [rtx-dns-install-v0.1.4.lua](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/v0.1.4/rtx-dns-install-v0.1.4.lua) |
| [v0.9.9](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.9.9) | Pre-release | [rtx-dns-install-v0.9.9.lua](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/v0.9.9/rtx-dns-install-v0.9.9.lua) |

YAMAHAルーターの**管理者コンソール**で、選んだ版の1行だけを実行します。先頭の`yes`は自動起動の指定です。自動起動を追加せずにインストールする場合は、この`yes`だけを`no`へ変更します。

<a id="version-v014"></a>

### v0.1.4をインストール

<!-- INSTALLER_COMMAND_V014_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local p="/lua/rtx-dns-install.lua";local function guard()local ok,s=rt.command("show status lua running","off");assert(ok and s);local n=0;for l in s:gmatch("[^"..string.char(13,10).."]+")do assert(l:match(":%s*(/%S+)%s*$")~=p,"Installer already running");if l:find("lua %-e ")and l:find("local DNSINSTALL_BOOT=",1,true)then n=n+1 end end;assert(n<=1,"Installer already running")end;guard();local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/f3852cca5c673a3c04f51edc14b75ebd105fe819/installer/versions/v0.1.4/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==24557,"Installer download failed");assert(r.body:find("-- Installer release: v0.1.4"..string.char(10),1,true),"Installer version mismatch");assert(loadstring(r.body));guard();rt.command("make directory /lua","off");local f=assert(io.open(p,"wb"));assert(f:write(r.body));assert(f:close());f=assert(io.open(p,"rb"));assert(f:read("*a")==r.body);assert(f:close());arg={[0]=p,[1]=DNSINSTALL_BOOT};dofile(p)'
```
<!-- INSTALLER_COMMAND_V014_END -->

<a id="version-v099"></a>

### v0.9.9をインストール

<!-- INSTALLER_COMMAND_V099_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local p="/lua/rtx-dns-install.lua";local function guard()local ok,s=rt.command("show status lua running","off");assert(ok and s);local n=0;for l in s:gmatch("[^"..string.char(13,10).."]+")do assert(l:match(":%s*(/%S+)%s*$")~=p,"Installer already running");if l:find("lua %-e ")and l:find("local DNSINSTALL_BOOT=",1,true)then n=n+1 end end;assert(n<=1,"Installer already running")end;guard();local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/f3852cca5c673a3c04f51edc14b75ebd105fe819/installer/versions/v0.9.9/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==24557,"Installer download failed");assert(r.body:find("-- Installer release: v0.9.9"..string.char(10),1,true),"Installer version mismatch");assert(loadstring(r.body));guard();rt.command("make directory /lua","off");local f=assert(io.open(p,"wb"));assert(f:write(r.body));assert(f:close());f=assert(io.open(p,"rb"));assert(f:read("*a")==r.body);assert(f:close());arg={[0]=p,[1]=DNSINSTALL_BOOT};dofile(p)'
```
<!-- INSTALLER_COMMAND_V099_END -->

- `yes`：起動確認後に自動起動を登録し、`save`で現在のルーター設定全体を保存します。他の未保存の設定変更も保存されます。
- `no`：自動起動設定と保存済みconfigを変更しません。すでにある自動起動設定は維持します。

画面に`DNSINSTALL (9/9) Installation complete`が出れば、インストールは終了しています。続いて表示される案内に従って**Enterキーを押すと、ルーターのコマンドプロンプトを再表示できます。** たとえばv0.9.9では、最後に次の2行を表示します。

```text
DNSINSTALL (9/9) Installation complete: v0.9.9; installer removed.
DNSINSTALL (9/9) Press ENTER to display the router command prompt.
```

ログの`(1/9)`～`(9/9)`は、下の「自動で行う処理」に対応する工程番号です。所要時間の割合ではなく、SHA256計算中の進捗にも、その工程の`(3/9)`を付けます。`no`を指定した場合も、自動起動設定を維持する工程として`(8/9)`を表示します。

`lua`コマンドは処理中でもコンソールのプロンプトを返し、その後にログが表示されるため、上の完了表示を待ってください。`(9/9)`だけでは完了とは限らず、`Installation complete`まで表示されたことを確認してください。完了後はインストーラーがEnter入力を待っているわけではありません。同じコマンドを重ねて実行する必要はありません。

既存の`/lua/rtx-dns.lua`と内容が同じなら、本体ファイルの上書きは省略します。ディスク上のファイルと稼働中の版が異なる場合もあるため、対象タスクは停止・再起動し、確認したファイルと現在のDNS設定を読み込みます。設定変更だけなら、ダウンロードを伴わない通常の[スクリプト再起動手順](install.md#update-script)も使用できます。

### インストーラーを手動で転送する場合

上の表から導入する版のインストーラーをダウンロードし、USBメモリ等でルーターの**`/lua/rtx-dns-install.lua`**へ保存します。配布ファイル名には版番号がありますが、ルーター上ではこの共通の一時ファイル名に変更して使用してください。

```text
lua /lua/rtx-dns-install.lua yes
```

開始時の引数には`yes`か`no`を必ず指定します。完了するとインストーラー自身と作業ファイルを削除します。この方法でも、本体の取得にはルーターからのHTTPS接続が必要です。

## 自動で行う処理

1. インストーラーに組み込んだ版番号・本体のサイズ・SHA256・取得URLと、ルーターの設定・実行状態を確認します。
2. その版の本体を、固定したcommitのHTTPS URLから1回取得し、サイズを確認します。Latestや別のmanifestは参照しません。
3. SHA256・Lua構文を確認します。この段階では現行DNSを停止しません。
4. 本体を作業ファイルへ書き込み、読み戻しを確認します。旧ファイルと以前の実行状態を復旧用に保存します。
5. 対象のDNSスクリプトだけを停止します。
6. 本体ファイルを差し替え、対象のDNSスクリプトを起動します。内容が同じ場合はファイルの差し替えを省略します。
7. 実行状態を複数回確認します。起動に失敗した場合は旧ファイルと以前の実行状態へ戻します。
8. `yes`の場合は、既存の同一スケジュールを使うか、1～999の範囲で空いている最小の番号を選び、保存します。`no`の場合は、自動起動設定と保存済みconfigを変更せず維持します。
9. 成功時に作業ファイルとインストーラーを削除し、完了とEnterキーの案内を表示します。

スケジュールの検索範囲はインストーラーの実装上の範囲です。別のスクリプトや他のスケジュールは変更しません。別の保存場所・独自の起動設定・NVR試験版からの移行には[通常の手順](install.md)を使用してください。

起動確認は対象Luaタスクが継続して実行されていることの確認です。導入後は利用する端末から`dig @ルーターのIPアドレス microsoft.com TXT +time=5 +tries=1`などで名前解決も確認できます。

## HTTPSでの配布方法

Releaseの配布先では署名付きの長いURLが使われます。RTX1210のHTTP APIで、そのURLが再エンコードされ署名検証に失敗する現象を確認したため、ルーターからの取得には短い`raw.githubusercontent.com`のHTTPS URLを使用します。

[`installer/versions/`](../installer/versions/)には、版ごとにReleaseの本体と`SHA256SUMS`のコピーを置きます。インストーラーは公開時に確認した本体のサイズ・SHA256を持ち、本体の取得先も40文字のcommit IDと版番号を含むURLに固定します。コマンド1行で取得するインストーラー自身のURLも、公開済みのcommitへ固定します。版を選び直すときは、その版のコマンドまたは配布ファイルを使用してください。

従来の「最新安定版を自動選択する」配布方法は終了しました。以前のコマンドは旧配布先を取得できず、現行DNSを停止する前に終了します。上記のバージョン別コマンドへ置き換えてください。

HTTPS対応のファームウェアとGitHubへ到達できるDNS・通信設定が必要です。HTTPSが利用できない環境では、インストーラーを使わずに[本体をUSBメモリ等で転送する手順](install.md)を使用してください。

RTX1210 Rev.14.01.42でv0.1.4・v0.9.9の導入、DNS応答、不正な本体の拒否を確認しました。[試験項目と結果](results/versioned-installer-2026-09-25.md)を参照してください。従来方式の実機結果は[過去の検証記録](results/installer-2026-09-25.md)として残しています。

## 途中で失敗した場合

エラーは`DNSINSTALL (n/9) failed`の形式で表示し、`n`には失敗した工程番号が入ります。その後の自動復旧や後始末のログにも、失敗した工程番号を付けます。起動失敗時の自動復旧が成功した場合は、`previous file and running state restored`も表示します。インストーラーは成功時だけ自身を削除するので、原因を修正してから再実行できます。

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
