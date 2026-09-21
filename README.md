ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

# RTX TCP DNS補完

本リポジトリをソースコードと配布ファイルの正本として管理します。

ライセンスは付与していません。生成方法と既存OSSとの照合結果は [コードの来歴と確認範囲](docs/code-provenance.md) を参照してください。

Yamaha RTXの内蔵UDP DNSと静的ホスト登録を維持し、LuaでTCP DNSを補完します。実機検証対象は **RTX830 Rev.15.02.33** と **RTX1210 Rev.14.01.42**、どちらも整数版Lua 5.1.5（機能1.08）です。RTX1300は未検証です。

```text
クライアント ── UDP/53 ── RTX内蔵DNS
             └─ TCP/53 ── Lua
                          ├─ RTXに登録した名前と完全一致 → RTX内蔵DNS（UDP）
                          └─ その他 → 上流DNS（TCP接続を再利用）
```

クライアントがUDPの切り詰め応答を受けてTCPへ再問い合わせする場合に、同じRTXのIPでTCP問い合わせを受け付ける構成です。Luaが内蔵DNSの上流通信を捕捉する仕組みではありません。内蔵DNSが切り詰め応答を返さず失敗するケースを、この仕組みだけで解消する保証もありません。

## ビルド済みファイルからの導入

[Releases](https://github.com/Yamar50/rtx-dns-tcp-lua/releases)の`rtx-dns.lua`は、そのままRTXへ転送して使うための配布ファイルです。Luaファイルの手編集や手元でのビルドは不要です。

起動時に`dns host`からアクセス許可、`ip host`／`dns static`からローカルの登録名、`dns server select`／`dns server`から上流DNSを読み取ります。TCP/53で待ち受け、256件のキャッシュを使い、終了時間を設けずに動作します。`dns host any`または省略時は、RTXの既定値どおり全ホストを許可します。

`/lua/rtx-dns.lua`へコピーした後は、次のコマンドで開始できます。`100`は未使用のスケジュール番号に置き換えます。

```text
lua /lua/rtx-dns.lua
schedule at 100 startup * lua /lua/rtx-dns.lua
save
```

手動起動の代わりに、スケジュールを保存してRTXを再起動しても開始できます。USBメモリからの転送、構文確認、更新・停止までの手順は[インストールと起動](docs/install.md)を参照してください。

## 秒間クエリ数の目安と検証機種

**動作検証済みはRTX830とRTX1210です。** 秒間クエリ数の参考値はRTX830での測定結果です。

| 条件（RTX830・LAN内の合成上流DNS） | 実測結果 |
|---|---|
| 512バイト応答 | **100クエリ/秒を1時間**、360,000件すべて正常受信 |
| 最大65,535バイト応答 | **30クエリ/秒を45秒**、1,350件すべて正常受信 |

いずれもキャッシュヒットに頼らず、上流TCP接続を再利用する条件です。家庭内での検討には、まず512バイト程度の応答で100クエリ/秒を処理できた実績を参考にできます。これは限界性能を測った値ではありません。

これらの負荷試験は`dns server select`対応前の実装で行いました。公開版では同機能とRTX1210での機能動作を追加検証していますが、同条件の長時間負荷試験は再実施していません。RTX1210の秒間クエリ数は未測定です。WAN越しの上流遅延や応答サイズでも性能は変わります。[測定条件の詳細](docs/validation.md#秒間クエリ数の参考測定)

## 実装内容

- 上流接続は固定設定で最大2本、RTXの規則を読み込む設定では既定で最大4本。同じ宛先の接続を規則間で共有します。1接続あたり4件のパイプライン、ID変換、順不同応答、部分送受信に対応。応答は最大65,535バイト。
- Lua起動時に稼働中configの `dns service` を確認し、recursiveなら `dns server select` と `dns server` を自動で読み取り、番号順に問い合わせ名・タイプ・元クライアントIPv4で選択します。
- キャッシュは最大256件・本文合計1MiB・TTL管理フィールド合計4,096個。参照時に期限確認し、容量不足時はLRUで追い出します。選択規則ごとにキーを分け、256件・1MiBの上限は全規則で共有します。毎秒の全件走査は行いません。
- キャッシュヒットではID、質問の大文字小文字、残りTTLを更新。正の通常応答のみ保存し、NXDOMAIN、NODATA、TTL=0、DNSSEC/特別なEDNSなどは保存しません。
- 接続試行は全体で平均毎秒1回、バースト2回まで。宛先別の待機は1→2→4→8→16→30秒。ソケット・送信元アドレス不足では新規接続を全体で30秒休止します。
- クライアント接続の受け入れに失敗した場合も1秒待機し、読み取り可能な待受ソケットを繰り返し処理する空回りを防ぎます。
- 同時クライアント32本、未完了問い合わせ32件、問い合わせ全体5秒、再試行1回。キャッシュと家庭内DNSは上流の回復待ちから独立しています。

最終的に解決できない問い合わせはSERVFAILを返して処理を終了します。その後の再問い合わせやDNSサーバーの選択は、クライアント側に委ねます。

上限を超えた応答はキャッシュを省略して中継します。キャッシュ本文の1MiBはLua全体のメモリ上限ではありません。管理情報・処理中のメッセージもメモリを使います。

確認した機種と機能は [検証範囲](docs/validation.md) を参照してください。

## ソースからのビルドとテスト

ビルドはPython 3の標準ライブラリだけを使用します。ローカルの単体テストにはLuaも必要です。生成物は1本のLuaファイルで、RTXへの追加ライブラリのインストールは不要です。

```sh
lua tests/test_wire_cache.lua
lua tests/test_dns_policy.lua
lua tests/test_auto_config.lua
lua tests/test_policy_wire.lua
lua tests/test_main.lua
lua tests/test_relay.lua
lua tests/cache_memory.lua
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tools/build.py --config config/example.lua --output build/rtx-dns.lua
```

`make test` / `make build` も利用できます。配布版は`python3 tools/build.py --config config/release.lua --output build/release/rtx-dns.lua`または`make release`で生成します。macOSでmakeがXcodeのライセンス確認に止まる場合は、上記の直接コマンドを使用できます。RTXは整数版Luaなので、小数の数値リテラル、32bit符号付き整数を超える直接計算、標準LuaSocket前提のコードを追加しないでください。

## 手動ビルド時の設定

以下は明示的な設定でビルドする場合の説明です。配布版は`config/release.lua`の`auto_config=true`により、待受・アクセス許可・ローカル登録名を自動設定します。

`config/example.lua` を `config/local.lua` にコピーして編集します。`config/local*.lua` はgit管理対象外です。

| 設定 | 意味 |
|---|---|
| `auto_config` | `true`なら起動時にRTXのDNSアクセス許可・ローカル登録名を読み取り、TCP/53で開始。配布版で使用 |
| `listen_host`, `listen_port` | RTX側の待受IPv4アドレス・ポート。試験は53053、内蔵UDP DNSをTCPで補完するときは53 |
| `allowed_clients` | 利用を許可するIPv4アドレスまたはCIDRの配列。明示必須 |
| `dns_config` | 通常は指定不要。試験用に`"static"`を指定した場合だけ稼働中configの自動読込を省略する。旧`"running"`指定も互換として受け付ける |
| `upstreams` | `dns_config="static"`の試験用固定設定で使う上流IPv4アドレス・TCPポート。1～2台 |
| `max_upstream_connections` | 全規則で共有する接続上限。既定は規則読込時4本、固定設定2本。明示指定は1～16本、実機検証は4本 |
| `policy_id` | 固定設定のキャッシュ識別子。規則読込時は規則番号に基づき自動設定 |
| `local_dns_host`, `local_dns_port` | 内蔵UDP DNSのIPv4アドレス・ポート |
| `local_zones` | 手動設定で内蔵DNSへ戻すゾーン。ラベル境界で一致し、子孫も対象。配布版では手動指定不要 |
| `local_names` | 内蔵DNSへ戻す登録名の完全一致リスト。配布版ではRTXの静的登録から自動取得 |
| `cache_entries`, `cache_bytes`, `cache_ttl_fields` | 初期値256、1048576、4096。entries=0で保存を無効化 |
| `duration` | 実行秒数。設定例は有限時間。省略すると明示的に停止するまで実行 |
| `console_log`, `syslog` | コンソール・syslogへの出力。設定例ではsyslogを無効化 |

通常はLua側のモード指定なしで、`rt.command("show config")` の結果を読みます。`dns service recursive`ならDNSの転送規則を使い、`dns service off`なら起動を中止してTCP待受を開始しません。サービス指定の省略時は、RTXの既定値に従いrecursiveとして扱います。**`dns server`や`dns server select`などのDNS設定を変更した後は、このLuaスクリプトを再起動してください。起動スケジュールを登録済みであれば、変更したconfigを`save`してRTX本体を再起動する方法でも反映されます。稼働中のLuaはDNS設定を自動再読込しません。**

設定全体をログへ出力せず、ルーターのconfigを変更しません。固定上流で過去の試験を再現するときだけ、`dns_config="static"`を明示して`upstreams`を使います。通常の自動設定では`upstreams`を使いません。

対応するのは静的IPv4の `dns server select`（1規則につき1〜2台）と、未一致時の `dns server`（最大4候補）です。小さい規則番号から最初に一致した規則を使い、その上流が失敗しても後続規則へ切り替えません。元クライアントの送信元IPv4を使い、単一IP・CIDR・開始IP～終了IP、通常のタイプ指定、`any`、PTRのIPv4/CIDR、`edns=on/off`を扱います。EDNS省略時はヤマハの既定どおりoffです。

`edns=off`では上流向けのOPT（DOやオプションを含む）を除去します。DNSSEC関連・特別なEDNS要求をキャッシュしない方針は維持します。`edns=on`では既存OPTを保持し、OPTのない要求には空OPTを追加します。これにより、以前の固定設定の透明中継と応答内容が変わる場合があります。

`select ... reject` は該当する問い合わせを破棄します。PP/DHCPからの動的上流取得、`restrict pp`、NAT46、IPv6上流、`reject ptr`などの未対応構文を検出すると、設定全体の読み込みを失敗させて起動しません。最大256規則・異なる上流宛先16個までです。

配布版はRTXの静的登録名を起動時に読み取り、その名前への問い合わせを内蔵UDP DNSに渡します。親ドメインや子孫の名前までローカル扱いにはしません。手動ビルドでは`local_zones`を使う従来の設定も可能です。ホスト名とIPの対応をLuaに複製して応答する処理は行いません。

LANで使う場合は、少なくとも次の設定を実際の環境に合わせて編集します。`192.0.2.0/24` は説明用のアドレスで、そのまま使用する値ではありません。

```lua
return {
  listen_host = "0.0.0.0", listen_port = 53,
  allowed_clients = { "192.0.2.0/24" },
  local_dns_host = "127.0.0.1", local_dns_port = 53,
  local_zones = { "home.arpa", "2.0.192.in-addr.arpa" },
  cache_entries = 256, cache_bytes = 1048576, cache_ttl_fields = 4096,
  stats_interval = 60,
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

## 常設と自動起動

有限時間の試験で動作を確認してから、`duration`を省略して再ビルドします。生成物をRTXのファイルシステムへ転送し、たとえば`/lua/rtx-dns.lua`に保存します。ファイル転送・保存は [Yamaha RTFSの説明](https://www.rtpro.yamaha.co.jp/RT/docs/rtfs/index.html) を参照してください。

管理者コンソールで実行し、動作確認後に未使用のスケジュール番号を選んで登録します。以下の`10`は例です。

```text
lua /lua/rtx-dns.lua
schedule at 10 startup * lua /lua/rtx-dns.lua
save
```

DNS設定を変更した場合は、`show status lua`で対象のタスクIDを確認し、`terminate lua <ID>`で停止してから再実行します。スクリプトだけの再起動でDNS設定を読み直せるため、RTX本体の再起動は必須ではありません。起動スケジュールを登録済みの場合は、設定を`save`してRTX本体を再起動しても反映されます。停止せずに重複起動しないでください。ログは`show log reverse`で`DNSRELAY`を確認します。

常設を解除する場合は、登録した番号の`no schedule at 10`と`save`を実行し、対象タスクを停止します。[起動スケジュールの公式仕様](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/schedule/schedule_at.html)

## 対応範囲と制限

- 通常のINクラスQUERYを対象とします。1メッセージ1質問、既定の問い合わせ上限4,096バイト。完全なDNSリゾルバーやdnsmasqの全機能ではありません。
- DNS UPDATE、AXFR/IXFR、TSIG/SIG(0)、EDNS TCP Keepaliveは拒否します。DNSSEC検証自体は行わず、対応する上流の回答を中継します。
- DNSSEC、CD/AD、ECS、COOKIEなどの特別な応答はキャッシュを避けます。未知RRのデータは変更しませんが、未対応のRR内の名前を指す特殊な圧縮形式は拒否する場合があります。
- IPv4の待受・上流を対象とします。IPv6接続、TLS、HTTPS、稼働中の家庭内ホスト登録の自動同期は含みません。
- 過負荷時はSERVFAILまたは接続失敗になります。クライアントのTCP接続待ち時間は、完全な問い合わせ受信後に始まる5秒の期限には含まれません。
- 期限判定はRTXの起動後経過秒数に基づき、秒単位です。
- 性能は上流DNSの待ち時間・応答サイズ・他のルーター処理によって変わります。機種共通の最大リクエスト数は定めていません。

## ファイル構成

- `src/`：DNS wire処理、キャッシュ、DNS選択規則、TCPリレー、起動処理。
- `config/release.lua`：転送・起動だけで利用する配布版の自動設定プロファイル。
- `config/example.lua`：ループバック限定・120秒の試験設定。
- `tools/build.py`：単一Luaファイルへの結合。
- `tools/serve_artifact.py`：生成物1ファイルの一時配布。
- `tests/`：単体テスト、合成DNSサーバー、負荷・障害試験用ハーネス。
- `tools/summarize_run.py` / `tools/plot_load.py`：測定結果の集計・描画。描画のみMatplotlibが必要です。

## 免責事項

本ソフトウェアは現状のまま提供します。動作、正確性、特定の目的への適合性を保証しません。利用者自身の責任で使用してください。本ソフトウェアの使用または使用不能によって生じた損害について、提供者は法令で認められる範囲において一切の責任を負いません。

## 参照資料

- [Yamaha Lua機能](https://www.rtpro.yamaha.co.jp/RT/docs/lua/)
- [dns service](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_service.html)
- [dns server select](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server_select.html)
- [dns server](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server.html)
