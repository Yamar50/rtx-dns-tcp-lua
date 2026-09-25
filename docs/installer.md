# 安定版をコマンド1行でインストール

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

ルーターがインターネットへHTTPS接続できれば、PCでファイルをダウンロードして転送する操作を省略できます。**最新の安定版だけ**を取得し、SHA256を照合してから`/lua/rtx-dns.lua`を起動します。Pre-releaseは選びません。

2026年9月25日時点では安定版は**v0.1.4**です。v0.9.9やNVR試験版を使う場合は、各Releaseの通常の転送手順を使用してください。このインストーラーを既存環境で使うと、その時点の安定版へ置き換わります。

## 実行方法

YAMAHAルーターの**管理者コンソール**で、次の1行を実行します。先頭の`yes`は自動起動の指定です。自動起動を追加せずにインストールする場合は、この`yes`だけを`no`へ変更します。

<!-- INSTALLER_COMMAND_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local p="/lua/rtx-dns-install.lua";local function guard()local ok,s=rt.command("show status lua running","off");assert(ok and s);local n=0;for l in s:gmatch("[^"..string.char(13,10).."]+")do assert(l:match(":%s*(/%S+)%s*$")~=p,"Installer already running");if l:find("lua %-e ")and l:find("local DNSINSTALL_BOOT=",1,true)then n=n+1 end end;assert(n<=1,"Installer already running")end;guard();local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/40fc6571e278784059fe299e047f83159f2cbbce/installer/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==24263,"Installer download failed");assert(loadstring(r.body));guard();rt.command("make directory /lua","off");local f=assert(io.open(p,"wb"));assert(f:write(r.body));assert(f:close());f=assert(io.open(p,"rb"));assert(f:read("*a")==r.body);assert(f:close());arg={[0]=p,[1]=DNSINSTALL_BOOT};dofile(p)'
```
<!-- INSTALLER_COMMAND_END -->

- `yes`：起動確認後に自動起動を登録し、`save`で現在のルーター設定全体を保存します。他の未保存の設定変更も保存されます。
- `no`：自動起動設定と保存済みconfigを変更しません。すでにある自動起動設定は維持します。

画面に`DNSINSTALL complete`が出れば完了です。`lua`コマンドは処理中でもコンソールのプロンプトを返すので、完了表示を待ってください。SHA256計算中は進捗を表示します。同じコマンドを重ねて実行する必要はありません。

既存の`/lua/rtx-dns.lua`と内容が同じなら、本体ファイルの上書きは省略します。ディスク上のファイルと稼働中の版が異なる場合もあるため、対象タスクは停止・再起動し、確認したファイルと現在のDNS設定を読み込みます。設定変更だけなら、ダウンロードを伴わない通常の[スクリプト再起動手順](install.md#update-script)も使用できます。

インストーラーをUSBメモリ等で転送する場合は、[rtx-dns-install.lua](../installer/rtx-dns-install.lua)を`/lua/rtx-dns-install.lua`へ保存し、次のように起動できます。

```text
lua /lua/rtx-dns-install.lua yes
```

開始時の引数には`yes`か`no`を必ず指定します。完了するとインストーラー自身と作業ファイルを削除します。

## 自動で行う処理

1. GitHubのLatestが示す安定版を確認します。
2. 版番号とSHA256が一体になった配布manifestを読み、本体をHTTPSで取得します。
3. SHA256とLua構文を確認します。この段階では現行DNSを停止しません。
4. 書き込みと読み戻しを確認してから、対象のDNSスクリプトだけを停止・差し替え・起動します。
5. 実行状態を複数回確認します。起動に失敗した場合は旧ファイルと以前の実行状態へ戻します。
6. `yes`の場合は、既存の同一スケジュールを使うか、1～999の範囲で空いている最小の番号を選び、保存します。
7. 成功時に作業ファイルとインストーラーを削除します。

スケジュールの検索範囲はインストーラーの実装上の範囲です。別のスクリプトや他のスケジュールは変更しません。別の保存場所・独自の起動設定・NVR試験版からの移行には[通常の手順](install.md)を使用してください。

起動確認は対象Luaタスクが継続して実行されていることの確認です。導入後は利用する端末から`dig @ルーターのIPアドレス microsoft.com TXT +time=5 +tries=1`などで名前解決も確認できます。

## HTTPSでの配布方法

Releaseの配布先では署名付きの長いURLが使われます。RTX1210のHTTP APIで、そのURLが再エンコードされ署名検証に失敗する現象を確認したため、インストーラーは短い`raw.githubusercontent.com`のHTTPS URLを使用します。

[`installer/stable/`](../installer/stable/)の本体と`SHA256SUMS`は、安定版ReleaseのAssetsをそのまま複製したものです。版番号とSHA256を単一manifestにまとめ、取得した本体との一致をルーター上でも確認します。Latestと配布manifestの版が異なる場合や、取得・照合に失敗した場合は、現行DNSを止めずに終了します。

HTTPS対応のファームウェアとGitHubへ到達できるDNS・通信設定が必要です。HTTPSが利用できない環境では[USBメモリ等による手順](install.md)を使用してください。

RTX1210 Rev.14.01.42で新規導入・更新・復旧などを確認しました。[試験項目と結果](results/installer-2026-09-25.md)を参照してください。

## 途中で失敗した場合

エラーは`DNSINSTALL failed`で表示します。起動失敗時の自動復旧が成功した場合は、`previous file and running state restored`も表示します。インストーラーは成功時だけ自身を削除するので、原因を修正してから再実行できます。

電源断などで作業ファイルが残った場合は、自動で上書きせず停止します。`show file list /lua`と`show status lua running`で状態を確認してください。

| ファイル | 用途 |
|---|---|
| `rtx-dns.install-old` | 差し替え前のファイル。復旧確認が済むまで保持します。 |
| `rtx-dns.install-new` | 照合済みの書き込み候補。 |
| `rtx-dns.install-state` | 対象版・SHA256・旧ファイルや実行状態の記録。 |

旧版へ手動で戻す場合は、対象スクリプトを停止して停止を確認し、`rtx-dns.install-old`を`rtx-dns.lua`へコピーしてから起動します。正常動作を確認してから残った作業ファイルを削除してください。`save`の応答が不明な場合は、確認済みの本体を保持するため、自動で旧版へ戻しません。自動起動設定と保存結果を確認してください。

## 配布を更新する開発者向け手順

安定版Releaseを公開した後、次を実行して生成した3ファイルを確認し、mainへ反映します。Pre-releaseの公開では安定版配布を更新しません。

```sh
python3 tools/prepare_stable_installer.py
```

インストーラー本体の変更時は、試験後に`python3 tools/build_installer.py`で再生成します。公開コマンドは`python3 tools/installer_command.py --ref <本体を含むcommitの40文字ID> --mode yes`で生成し、このページも更新します。コマンドは確認済みのインストーラーのcommitを固定しますが、導入するDNSスクリプトは実行時点の最新安定版です。
