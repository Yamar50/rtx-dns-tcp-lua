# コマンド1行でアンインストール

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

オンラインインストーラーや標準手順で導入した **`/lua/rtx-dns.lua`を停止し、自動起動設定と本体ファイルを削除します。** YAMAHAルーターの内蔵DNS設定は維持され、追加したTCPフォールバック機能が停止します。ルーターの再起動は不要です。

## WebGUIから実行

1. YAMAHAルーターへ管理者権限でログインし、**［管理］→［保守］→［コマンドの実行］**を開きます。
2. 次の1行を貼り付け、［実行］を押します。管理者コンソールでも同じコマンドを使えます。

<!-- UNINSTALL_COMMAND_START -->
```text
lua -e 'local DNSINSTALL_BOOT="uninstall";local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/5c424af2b1fb645dccadad8f9376fdd19d940135/installer/rtx-dns-uninstall.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==6480,"Uninstaller download failed");assert(loadstring(r.body))(DNSINSTALL_BOOT)'
```
<!-- UNINSTALL_COMMAND_END -->

アンインストーラーを固定したcommitのHTTPS URLから取得してメモリ上で実行します。ルーターへの手動ファイル転送は不要です。削除対象は版番号によらず共通です。

3. 数秒待って、同じ画面で次の確認コマンドを実行します。

```text
show status lua
show file list /lua
```

**WebGUIの「成功」はコマンドを受け付けた表示で、アンインストールの完了表示ではありません。** Luaの進捗メッセージはWebGUIのコマンド実行ログには出ません。`show status lua`の履歴で、今回の時刻の`DNSINSTALL_BOOT=\"uninstall\"`を含むコマンドが「正常終了」し、実行中の一覧に`/lua/rtx-dns.lua`がなく、ファイル一覧にも本体がないことを確認してください。全文が読みづらい場合は［テキストファイルで取得］を利用できます。

SYSLOGにも次の完了メッセージを記録します。ログ設定自体は変更しません。

```text
DNSUNINSTALL complete: /lua/rtx-dns.lua removed; startup schedules removed and configuration saved
```

RTX1210のWebGUIでは`show log`系や`show status lua | grep ...`が「禁止」になることを確認しています。コマンド実行画面では`show status lua`をそのまま使い、ブラウザのページ内検索やテキストファイル取得で確認してください。SYSLOGはWebGUIの専用表示機能を利用します。

管理者コンソールでは、`DNSUNINSTALL (7/7) Uninstallation complete`も表示します。最後のEnter案内はコンソール利用者向けです。

## 削除する範囲

- 実行中の`/lua/rtx-dns.lua`を停止します。
- `schedule at 番号 startup * lua /lua/rtx-dns.lua`に完全一致する設定をすべて削除します。
- 設定の変更結果を照合し、`save`で保存してから、`/lua/rtx-dns.lua`だけを削除します。

別のLuaスクリプトやスケジュール、DNS関連の設定、`/lua`ディレクトリは削除しません。削除済みの状態で再実行しても完了できます。**`save`では、他の未保存の変更も含めて現在のルーター設定全体が保存されます。** WebGUIにもコマンド実行時の自動保存があります。

別の保存先、引数付きなど独自の起動設定、NVR試験版は自動削除の対象外です。インストーラーの復旧用ファイルが残っている場合や、別のインストーラーが動いている場合も、変更前に停止します。

## 失敗した場合と再導入

失敗した処理を「正常終了」として扱わず、Luaの実行履歴にエラーを残します。SYSLOGが利用できれば`DNSUNINSTALL failed:`も記録します。

設定保存までに失敗した場合は、本体ファイルを残します。ただし、DNSタスクの停止や一部のスケジュール解除がすでに済んでいる場合があります。エラーの原因を解消してから同じコマンドを再実行してください。インストーラーの復旧用ファイルがある場合は、[インストーラーの復旧手順](installer.md#途中で失敗した場合)を先に確認します。

再び使うときは、[オンラインインストール](installer.md)で導入する版を選び、`yes`で実行すると本体と自動起動設定を再導入できます。

RTX1210 Rev.14.01.42で、WebGUIからのアンインストール、削除済み状態での再実行、v0.9.9の再導入を確認しました。[試験結果](results/webgui-uninstaller-2026-09-25.md)を参照してください。

## 開発者向け

読みやすいソースは[`src/uninstaller.lua`](../src/uninstaller.lua)、単体配布ファイルは[`installer/rtx-dns-uninstall.lua`](../installer/rtx-dns-uninstall.lua)です。

```sh
make uninstaller
lua tests/test_uninstaller.lua
python3 -m unittest discover -s tests -p 'test_uninstaller_tools.py'
```

生成物をcommitした後、`python3 tools/build_uninstaller.py --ref <40文字のcommit ID>`で公開用のコマンドを作成します。DNS本体と既存のバージョン別インストーラーは変更しません。
