# インストールと起動

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

この手順はv0.9.9の共通ファイルを対象とします。機種ごとの最低ファームウェアと確認状況は[対応機種の管理表](compatibility.md)を参照してください。

## ビルド済みファイル

GitHubの[v0.9.9 Release](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.9.9)のAssetsから`rtx-dns.lua`をダウンロードします。1本のLuaファイルに必要な本体と自動設定処理を含み、追加ライブラリ・Python・手編集は不要です。

配布版は起動時にYAMAHAルーターのconfigを読み、TCP/53で待ち受けます。

- 上流DNS：`dns server select`を番号順で評価。v0.9.9ではIPv6のみで利用できない規則を除外し、条件に合う後続select、次に通常DNSのIPv4を使います。通常DNSは固定の`dns server`、`dns server pp`、NVRの`dns server pdp`、`dns server dhcp`の優先順です。PDP取得は未対応で、PP未取得やPDP未対応を理由に下位DHCPへ切り替えません。
- アクセス許可：`dns host`の単一IP・IP範囲・対応インターフェースのネットワークを使用。`any`または省略時はYAMAHAルーターの既定値どおり全ホストを許可。`none`なら起動しません。
- ローカル名：`ip host`・`dns static`に登録された名前を内蔵UDP DNSへ問い合わせる。個別の`local_zones`設定は不要。
- キャッシュ：256件。実行時間の制限なし。統計は60秒間隔でsyslogへ出力。
- 送信元IPごとの制限：TCP接続4本、平均20問い合わせ/秒・バースト40件。手編集なしで有効になり、切断・再接続でも問い合わせ枠はリセットしません。全体では32接続までです。

`dns service off`、重複規則番号・入力上限超過・アクセス許可を確定できない設定では起動を中止します。固定IPv4のほか、PP・DHCPで取得したIPv4 DNSにも対応します。取得元不明や未対応上流に該当する問い合わせはSERVFAILにします。利用するDNSの設定は事前にYAMAHAルーター側で行ってください。[選択規則と例外時の動作](dns-policy.md)を参照してください。

### `dns host lan1`と別セグメントからの利用

`dns host lan1`では、LAN1のプライマリー・セカンダリーIPv4アドレスとマスクから許可範囲を作り、接続元IPを照合します。LAN1経由で到達しただけでは、範囲外の別セグメントは許可されません。別のLANも許可する場合は、YAMAHAルーターの`dns host`に対象インターフェースやIP範囲を併記します。例えばLAN1とLAN2なら`dns host lan1 lan2`です。実際の構成に合わせて設定し、変更後にスクリプトを再起動してください。

待受はIPv4の全アドレスのTCP/53です。YAMAHAルーターのLua APIの`tcp:bind()`が指定するのはIPアドレスで、インターフェース名を指定する機能はありません。待受IPと利用端末の許可は別に扱い、許可されない接続元は問い合わせを処理せず切断します。既存のIPフィルターも適用されます。

`dns host lan`にはLAN・タグVLAN・LAN分割・VLAN・bridgeを含み、WAN・ONUは含めません。直接の`dns host lanN.M`は未確認構文のため起動を中止します。[インターフェース名と用途](compatibility.md#interface-forms)を参照してください。

現在の自動設定はconfigに記述された静的IPv4アドレスを対象とします。許可範囲に必要なインターフェースがDHCPなどで動的にアドレスを取得する構成では、範囲を推測せず起動を中止します。

初めて導入する場合は以下へ進みます。既存版の更新は[設定変更と更新](#update-script)、NVR試験版からの切替は[移行手順](#nvr-migration)を先に確認してください。

## 初回インストール

安定版だけを自動取得・SHA256照合・起動する場合は、[コマンド1行のインストーラー](installer.md)も利用できます。Pre-releaseのv0.9.9には以下の転送手順を使用してください。

USBメモリやmicroSDカード、SFTP等でインストールします。機種が備える転送方法を使用してください。

### 例）USBメモリを使用する場合

1. ダウンロードした`rtx-dns.lua`をFAT/FAT32形式のUSBメモリのルートに保存し、YAMAHAルーターに接続します。添付の`SHA256SUMS`で、転送前のファイルのSHA-256を確認できます。
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

## YAMAHAルーター起動時の自動実行

`100`は例です。既存のスケジュールと重複しない番号に置き換えます。

```text
schedule at 100 startup * lua /lua/rtx-dns.lua
save
```

手動起動済みなら、そのまま利用できます。まだ起動していない場合は`lua /lua/rtx-dns.lua`で開始するか、自動起動設定を保存してYAMAHAルーター本体を再起動します。

`lua use`は既定で`on`です。利用環境で明示的に`lua use off`にしている場合は、Lua機能を有効にする必要があります。

## 動作確認

端末からYAMAHAルーターのIPアドレスへTCPで問い合わせます。以下の`192.0.2.1`は説明用なので、実際のYAMAHAルーターのIPへ置き換えてください。

```sh
dig @192.0.2.1 google.com TXT +tcp
dig @192.0.2.1 router.home.arpa A +tcp
```

2つ目の名前はYAMAHAルーターに登録した実際のホスト名に置き換えます。クライアントは従来どおりYAMAHAルーターをDNSとして使います。UDPの切り詰め応答を受けてTCPへ切り替えるクライアントは、同じIPのTCP/53へ接続できます。

<a id="update-script"></a>

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

自動起動を設定済みなら、変更したconfigを`save`してYAMAHAルーター本体を再起動する方法でも反映されます。スクリプトだけの再起動でもよく、YAMAHAルーターの再起動は必須ではありません。

ファイルを更新するときも、対象スクリプトを停止してからコピーします。コピー後は`luac -p /lua/rtx-dns.lua`を実行し、構文確認が終了してから別のコマンドとして`lua /lua/rtx-dns.lua`で起動します。既存の起動スケジュールはそのまま使用します。`copy`は同名ファイルを上書きするため、必要なら現在のファイルを別名に保存してから入れ替えてください。

自動起動を解除する場合は、登録した番号のスケジュールを削除して保存し、実行中の対象スクリプトを停止します。

```text
no schedule at 100
save
terminate lua file /lua/rtx-dns.lua
```

<a id="nvr-migration"></a>

## NVR試験版から共通ファイルへの移行

`nvr-dns.lua`を使用していた場合は、**新しいファイルをコピーする前に**旧タスクを停止します。次のパスは実際の配置先に合わせてください。

```text
terminate lua file /lua/nvr-dns.lua
show status lua running
```

旧ファイルを起動するスケジュールも解除します。次の`100`は旧スクリプトを登録した番号に置き換えてください。

```text
no schedule at 100
```

旧タスクの停止を確認してから、初回インストールと同じ手順で`rtx-dns.lua`をコピー・構文確認・起動します。新しい自動起動コマンドを登録し、`save`で保存してください。旧版と新版を同時に起動しないでください。

## 起動しない・名前解決できない場合

**不具合の報告や「この機種で動いた」という動作報告をいただけると嬉しいです。** [GitHub Issues](https://github.com/Yamar50/rtx-dns-tcp-lua/issues/new/choose)から「不具合の報告」または「動作の報告」を選んで、分かる範囲でご記入ください。

`show status lua`と`show log`で、対象タスクと`DNSRELAY`のエラーログを確認してください。機種・ファームウェアが[動作が見込まれる機種の表](compatibility.md)の条件を満たすか、設定に[検出対象のインターフェース名](compatibility.md#interface-forms)以外が含まれないかを確認できます。

一覧にない名前を使用していて起動や名前解決に失敗する場合は、[GitHub Issues](https://github.com/Yamar50/rtx-dns-tcp-lua/issues)でお知らせください。コードを調べたり書き換えたりする必要はありません。 GitHubにログインし、**Issues → New issue**で報告の種類を選び、フォームに記入して送信できます。機種・ファームウェアRev.・スクリプトの版・エラーログ・該当設定行を添え、パスワードなどの認証情報は含めないでください。設定全体は不要です。一覧にある名前でも、APIやアクセス許可など別の原因で失敗する場合があります。

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
