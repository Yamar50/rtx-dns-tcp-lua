# 開発・検証用の手動設定と一時実行

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

このページは、試験ポート・送信元・ローカルゾーンなどを明示して過去の試験を再現する場合の資料です。通常のインストールでは、ここにある編集・試験用ビルド・再ビルドは不要です。[インストールと起動](install.md)に従い、Releaseの`rtx-dns.lua`をそのまま使ってください。

`make build`は`config/example.lua`を使い、ループバック限定・120秒の試験ファイルを生成します。通常配布版は`make release`で生成します。

## 試験用の手動設定

以下は開発・検証のため、明示的な設定でビルドする場合の説明です。配布版は`config/release.lua`の`auto_config=true`により、待受・アクセス許可・ローカル登録名を自動設定します。

`config/example.lua` を `config/local.lua` にコピーして編集します。`config/local*.lua` はgit管理対象外です。

| 設定 | 意味 |
|---|---|
| `max_clients_per_ip` | 同じ送信元IPからのTCP接続上限。既定4、設定範囲1〜32。全体の上限32とは別に適用 |
| `query_rate_per_ip`, `query_burst_per_ip` | IP単位の問い合わせ枠の毎秒補充数と最大蓄積数。既定20件/秒・40件、設定範囲はそれぞれ1〜1000。全接続で共有し、切断しても枠を保持 |
| `max_client_ips` | 送信元の管理表の上限。既定256、`max_clients`以上4096以下。接続中・利用枠が未回復のIPは追い出さない |
| `auto_config` | `true`なら起動時にRTXのDNSアクセス許可・ローカル登録名を読み取り、TCP/53で開始。配布版で使用 |
| `listen_host`, `listen_port` | RTX側の待受IPv4アドレス・ポート。試験は53053、内蔵UDP DNSをTCPで補完するときは53 |
| `allowed_clients` | 利用を許可するIPv4アドレス・IP範囲・CIDRの配列。自動設定を使わない場合に明示必須 |
| `dns_config` | 通常は指定不要。試験用に`"static"`を指定した場合だけ稼働中configの自動読込を省略する。旧`"running"`指定も互換として受け付ける |
| `upstreams` | `dns_config="static"`の試験用固定設定で使う上流IPv4アドレス・TCPポート。1～2台 |
| `max_upstream_connections` | 全規則で共有する接続上限。既定は規則読込時4本、固定設定2本。明示指定は1～16本、実機検証は4本 |
| `policy_id` | 固定設定のキャッシュ識別子。規則読込時は規則番号に基づき自動設定 |
| `local_dns_host`, `local_dns_port` | 内蔵UDP DNSのIPv4アドレス・ポート |
| `local_zones` | 手動設定で内蔵DNSへ戻すゾーン。ラベル境界で一致し、子孫も対象。配布版では使用せず、静的登録名の完全一致で振り分け |
| `local_names` | 内蔵DNSへ戻す登録名の完全一致リスト。配布版ではRTXの静的登録から自動取得 |
| `cache_entries`, `cache_bytes`, `cache_ttl_fields` | 初期値256、1048576、4096。entries=0で保存を無効化 |
| `duration` | 実行秒数。設定例は有限時間。省略すると明示的に停止するまで実行 |
| `console_log`, `syslog` | コンソール・syslogへの出力。設定例ではsyslogを無効化 |

手動設定でLAN上の試験を行う場合は、次の試験設定を実際の環境に合わせて編集します。`192.0.2.0/24` は説明用のアドレスで、そのまま使用する値ではありません。

```lua
return {
  listen_host = "0.0.0.0", listen_port = 53,
  allowed_clients = { "192.0.2.0/24" },
  local_dns_host = "127.0.0.1", local_dns_port = 53,
  local_zones = { "home.arpa", "2.0.192.in-addr.arpa" },
  cache_entries = 256, cache_bytes = 1048576, cache_ttl_fields = 4096,
  duration = 120, stats_interval = 60,
  console_log = false, syslog = true
}
```

`0.0.0.0` はルーターが受信するIPv4アドレスで待ち受けます。VRRPの仮想IPについては、そのルーターがMASTERになっているアドレスで利用します。`allowed_clients` は利用するLANに限定してください。内蔵DNSにもループバックから問い合わせ可能な設定が必要です。

## RTXでの一時実行

設定をビルドし、生成物1ファイルだけをルーターへ提供します。次のIPは説明用です。配布ホストを`192.0.2.10`、ルーターを`192.0.2.1`として記述しています。実際のアドレスに置き換えてください。

```sh
python3 tools/build.py --config config/local.lua --output build/rtx-dns.lua
python3 tools/serve_artifact.py --file build/rtx-dns.lua \
  --bind 192.0.2.10 --allow 192.0.2.1 --port 18880 --duration 120
```

RTXの管理者コンソールから実行します。

```text
lua -e 'local r=rt.httprequest({url="http://192.0.2.10:18880/artifact.lua",method="GET"}); assert(r.body); local f,e=loadstring(r.body); assert(f,e); f()'
```

この方法ではルーター上のファイル保存・設定のsave・自動起動追加を行いません。配布サーバーは指定ファイルを起動時に読み込み、指定ルーターからの `/artifact.lua` だけを提供し、指定時間後に終了します。LAN内HTTPでコードを取得するため、管理下の経路で使用してください。常設時は、確認した生成物をルーターのLua保存領域へ配置する運用に切り替えてください。

`show status lua` で今回のタスクIDを確認し、必要なら `terminate lua <ID>` でそのタスクだけを停止します。既存のLuaタスクをまとめて停止しないでください。有限時間で起動した場合は自動終了します。

試験用ポートへの問い合わせ例：

```sh
dig -b 192.0.2.10 @192.0.2.1 -p 53053 router01.home.arpa A +tcp
```

TCP/53に配置した場合は `-p 53053` を外します。家庭内DNSの回答がUDP側でも切り詰められる場合、このローカル転送経路では回答を大きくできません。

## 手動設定の試験版を常設する場合

有限時間の試験で動作を確認してから、`duration`を省略して再ビルドします。生成物をRTXのファイルシステムへ転送し、たとえば`/lua/rtx-dns.lua`に保存します。ファイル転送・保存は [Yamaha RTFSの説明](https://www.rtpro.yamaha.co.jp/RT/docs/rtfs/index.html) を参照してください。

管理者コンソールで実行し、動作確認後に未使用のスケジュール番号を選んで登録します。以下の`10`は例です。

```text
lua /lua/rtx-dns.lua
schedule at 10 startup * lua /lua/rtx-dns.lua
save
```

DNS設定を変更した場合は、`show status lua`で対象のタスクIDを確認し、`terminate lua <ID>`で停止してから再実行します。スクリプトだけの再起動でDNS設定を読み直せるため、RTX本体の再起動は必須ではありません。起動スケジュールを登録済みの場合は、設定を`save`してRTX本体を再起動しても反映されます。停止せずに重複起動しないでください。ログは`show log reverse`で`DNSRELAY`を確認します。

常設を解除する場合は、登録した番号の`no schedule at 10`と`save`を実行し、対象タスクを停止します。[起動スケジュールの公式仕様](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/schedule/schedule_at.html)
