# インストールと起動

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

> このブランチの説明はv0.9.9候補版を対象にしています。候補版は負荷試験中の再起動を調査しており、公開保留中です。現在配布している安定版v0.1.4の導入には、[その版の手順](https://github.com/Yamar50/rtx-dns-tcp-lua/blob/v0.1.4/docs/install.md)を参照してください。

## ビルド済みファイル

公開後はGitHubの[Releases](https://github.com/Yamar50/rtx-dns-tcp-lua/releases)から対象版の`rtx-dns.lua`をダウンロードします。1本のLuaファイルに必要な本体と自動設定処理を含み、追加ライブラリ・Python・手編集は不要です。利用するネットワークの情報をビルド時に埋め込んでいません。

配布版は起動時にRTXのconfigを読み、TCP/53で待ち受けます。

- 上流DNS：`dns server select`を番号順で評価。v0.9.9ではIPv6のみで利用できない規則を除外し、条件に合う後続select、次に通常DNSのIPv4を使います。通常DNSは固定の`dns server`、`dns server pp`、NVRの`dns server pdp`、`dns server dhcp`の優先順です。PDP取得は未対応で、PP未取得やPDP未対応を理由に下位DHCPへ切り替えません。
- アクセス許可：`dns host`の単一IP・IP範囲・対応インターフェースのネットワークを使用。`any`または省略時はRTXの既定値どおり全ホストを許可。`none`なら起動しません。
- ローカル名：`ip host`・`dns static`に登録された名前を内蔵UDP DNSへ問い合わせる。個別の`local_zones`設定は不要。
- キャッシュ：256件。実行時間の制限なし。統計は60秒間隔でsyslogへ出力。
- 送信元IPごとの制限：TCP接続4本、平均20問い合わせ/秒・バースト40件。手編集なしで有効になり、切断・再接続でも問い合わせ枠はリセットしません。全体では32接続までです。

`dns service off`、重複規則番号・入力上限超過・アクセス許可を確定できない設定では起動を中止します。固定IPv4のほか、PP・DHCPで取得したIPv4 DNSにも対応します。取得元不明や未対応上流に該当する問い合わせはSERVFAILにします。利用するDNSの設定は事前にRTX側で行ってください。[選択規則と例外時の動作](dns-policy.md)を参照してください。

### `dns host lan1`と別セグメントからの利用

`dns host lan1`では、LAN1のプライマリー・セカンダリーIPv4アドレスとマスクから許可範囲を作り、接続元IPを照合します。LAN1経由で到達しただけでは、範囲外の別セグメントは許可されません。別のLANも許可する場合は、RTXの`dns host`に対象インターフェースやIP範囲を併記します。例えばLAN1とLAN2なら`dns host lan1 lan2`です。実際の構成に合わせて設定し、変更後にスクリプトを再起動してください。

待受はIPv4の全アドレスのTCP/53です。RTXのLua APIの`tcp:bind()`が指定するのはIPアドレスで、インターフェース名を指定する機能はありません。待受IPと利用端末の許可は別に扱い、許可されない接続元は問い合わせを処理せず切断します。既存のIPフィルターも適用されます。

`dns host lan`にはLAN・タグVLAN・LAN分割・VLAN・bridgeを含み、WAN・ONUは含めません。直接の`dns host lanN.M`は未確認構文のため起動を中止します。[インターフェース名と用途](compatibility.md#interface-forms)を参照してください。

現在の自動設定はconfigに記述された静的IPv4アドレスを対象とします。許可範囲に必要なインターフェースがDHCPなどで動的にアドレスを取得する構成では、範囲を推測せず起動を中止します。

## 初回インストール

USBメモリやmicroSDカード、SFTP等でインストールします。

### 例）USBメモリを使用する場合

1. ダウンロードした`rtx-dns.lua`をFAT/FAT32形式のUSBメモリのルートに保存し、RTXに接続します。添付の`SHA256SUMS`で、転送前のファイルのSHA-256を確認できます。
2. 管理者コンソールでファイルを確認します。

```text
show file list usb1:/
show file list /
```

`/lua`ディレクトリがない場合だけ、次を実行します。

```text
make directory /lua
```

ファイルをコピーし、Luaの構文を確認します。

コンソールのコマンドは1行ずつ実行し、各コマンドの終了を確認してから次へ進みます。特に`luac`の実行中に起動コマンドをまとめて送信しないでください。

```text
copy usb1:/rtx-dns.lua /lua/rtx-dns.lua
show file list /lua
luac -p /lua/rtx-dns.lua
```

3. 構文エラーがなければ、次のコマンドで起動します。

```text
lua /lua/rtx-dns.lua
show status lua
show log
```

`show status lua`で対象ファイルが`[running]`となり、ログに`DNSRELAY`の起動記録があることを確認します。`lua`コマンドは起動後にプロンプトを返すため、`&`は不要です。同じファイルを重複起動しないでください。

## RTX起動時の自動実行

`100`は例です。既存のスケジュールと重複しない番号に置き換えます。

```text
schedule at 100 startup * lua /lua/rtx-dns.lua
save
```

手動起動済みなら、そのまま利用できます。まだ起動していない場合は`lua /lua/rtx-dns.lua`で開始するか、自動起動設定を保存してRTX本体を再起動します。

`lua use`は既定で`on`です。利用環境で明示的に`lua use off`にしている場合は、Lua機能を有効にする必要があります。

## 動作確認

端末からRTXのIPアドレスへTCPで問い合わせます。以下の`192.0.2.1`は説明用なので、実際のRTXのIPへ置き換えてください。

```sh
dig @192.0.2.1 google.com TXT +tcp
dig @192.0.2.1 router.home.arpa A +tcp
```

2つ目の名前はRTXに登録した実際のホスト名に置き換えます。クライアントは従来どおりRTXをDNSとして使います。UDPの切り詰め応答を受けてTCPへ切り替えるクライアントは、同じIPのTCP/53へ接続できます。

## 設定変更と更新

`dns server`、`dns server select`、`dns host`、静的ホスト名、対象インターフェースのIPなどを変更した後は、スクリプトを再起動します。設定は起動時に読み取り、稼働中には自動再読込しません。PP・DHCPで取得したDNSアドレスと必要なPP接続状態だけは30秒ごとに確認するため、同じ設定のまま取得アドレスが変わった場合の再起動は不要です。

```text
terminate lua file /lua/rtx-dns.lua
show status lua running
```

対象が停止したことを確認してから実行します。

```text
lua /lua/rtx-dns.lua
show status lua
```

自動起動を設定済みなら、変更したconfigを`save`してRTX本体を再起動する方法でも反映されます。スクリプトだけの再起動でもよく、RTXの再起動は必須ではありません。

ファイルを更新するときも、対象スクリプトを停止してからコピーします。`copy`は同名ファイルを上書きするため、必要なら現在のファイルを別名に保存してから入れ替えてください。

自動起動を解除する場合は、登録した番号のスケジュールを削除して保存し、実行中の対象スクリプトを停止します。

```text
no schedule at 100
save
terminate lua file /lua/rtx-dns.lua
```

## 免責事項

本ソフトウェアは現状のまま提供します。動作、正確性、特定の目的への適合性を保証しません。利用者自身の責任で使用してください。本ソフトウェアの使用または使用不能によって生じた損害について、提供者は法令で認められる範囲において一切の責任を負いません。

## 公式資料

- [RTFS：ファイル保存・コピー](https://www.rtpro.yamaha.co.jp/RT/docs/rtfs/index.html)
- [Luaの実行](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/lua_script/lua.html)
- [構文確認](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/lua_script/luac.html)
- [起動スケジュール](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/schedule/schedule_at.html)
- [実行状態](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/lua_script/show_status_lua.html)
- [Luaの停止](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/lua_script/terminate_lua.html)
- [DNSのアクセス許可](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_host.html)
- [LuaソケットAPI](https://www.rtpro.yamaha.co.jp/RT/docs/lua/rt_api.html)
- [静的DNSレコード](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/ip_host.html)
