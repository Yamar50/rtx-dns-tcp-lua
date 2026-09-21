ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

# RTX TCP DNS補完

このリポジトリには、MITなどのソフトウェアライセンスを設定していません。生成方法と既存OSSとの照合結果は [コードの来歴と確認範囲](docs/code-provenance.md) を参照してください。

Yamaha RTXの内蔵UDP DNSと静的ホスト登録を維持し、LuaでTCP DNSを補完します。実機検証対象は **RTX830 Rev.15.02.33** と **RTX1210 Rev.14.01.42**、どちらも整数版Lua 5.1.5（機能1.08）です。RTX1300は未検証です。

```text
クライアント ── UDP/53 ── RTX内蔵DNS
             └─ TCP/53 ── Lua
                          ├─ RTXに登録した簡易DNSのレコードと完全一致 → RTX内蔵DNS（UDP）
                          └─ その他 → 上流DNS（TCP接続を再利用）
```

クライアントがUDPの切り詰め応答を受けてTCPへ再問い合わせする場合に、同じRTXのIPでTCP問い合わせを受け付ける構成です。Luaが内蔵DNSの上流通信を捕捉する仕組みではありません。RTX内蔵DNSをTCPで補完し、大きなDNS応答をクライアントへ返せるようにするのが、このスクリプトの目的です。

## ビルド済みファイルからの導入

[Releases](https://github.com/Yamar50/rtx-dns-tcp-lua/releases)の`rtx-dns.lua`は、そのままRTXへ転送して使うための配布ファイルです。Luaファイルの手編集や手元でのビルドは不要です。

起動時に`dns host`からアクセス許可、`ip host`／`dns static`からローカルの登録名、`dns server select`／`dns server`から上流DNSを読み取ります。TCP/53で待ち受け、256件のキャッシュを使い、終了時間を設けずに動作します。`dns host any`または省略時は、RTXの既定値どおり全ホストを許可します。

USBメモリやmicroSDカード、SFTP等でインストールします。`/lua/rtx-dns.lua`へコピーした後は、次のコマンドで開始できます。`100`は未使用のスケジュール番号に置き換えます。

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
- 送信元IPごとにTCP接続は4本、問い合わせは平均20件/秒・バースト40件まで。同じIPの全接続で合算し、キャッシュ・ローカル名・不正な問い合わせも数えます。切断・再接続しても利用枠はリセットしません。

接続数超過時は新しい接続を切断します。クエリ数超過時はその問い合わせにSERVFAILを返し、受け付け済みの処理・応答を既存の期限内で完了してから接続を閉じます。問い合わせ枠が回復するまで新しい接続も拒否します。送信元の管理表は最大256 IPで、満杯時は接続がなく利用枠が全回復したIPだけを入れ替えます。安全に入れ替えられなければ、新しいIPからの接続を拒否します。

この制限はLuaが受け付けるTCP問い合わせに適用します。RTX内蔵DNSのUDP問い合わせには適用しません。NATや別のDNS中継サーバー経由で複数端末が同じ送信元IPに見える場合は、そのIP全体で上限を共有します。20件/秒は保護のための既定値で、機器の限界性能ではありません。これらの制限値はファイルの手編集なしで有効になります。

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
python3 tools/build.py --config config/release.lua --output build/release/rtx-dns.lua
```

`make test` / `make release` も利用できます。上記のビルドは、Releaseと同じ自動設定プロファイルを使います。macOSでmakeがXcodeのライセンス確認に止まる場合は、上記の直接コマンドを使用できます。RTXは整数版Luaなので、小数の数値リテラル、32bit符号付き整数を超える直接計算、標準LuaSocket前提のコードを追加しないでください。

## RTXのconfigからの自動設定

配布版では`allowed_clients`、`local_dns_host`、`local_zones`などを編集する必要はありません。`dns host`から許可する端末・LANを、`ip host`・`dns static`からローカル登録名を読み取ります。内蔵DNSの問い合わせ先も自動で選びます。

待受は全IPv4アドレスのTCP/53です。VRRPの仮想IPは、そのルーターがMASTERになっているアドレスで利用します。アクセス許可はRTX側の`dns host`に従います。

配布版は起動時に、`rt.command("show config")` の結果を読みます。`dns service recursive`ならDNSの転送規則を使い、`dns service off`なら起動を中止してTCP待受を開始しません。サービス指定の省略時は、RTXの既定値に従いrecursiveとして扱います。**`dns server`や`dns server select`などのDNS設定を変更した後は、このLuaスクリプトを再起動してください。起動スケジュールを登録済みであれば、変更したconfigを`save`してRTX本体を再起動する方法でも反映されます。稼働中のLuaはDNS設定を自動再読込しません。**

設定全体をログへ出力せず、ルーターのconfigを変更しません。

対応するのは静的IPv4の `dns server select`（1規則につき1〜2台）と、未一致時の `dns server`（最大4候補）です。小さい規則番号から最初に一致した規則を使い、その上流が失敗しても後続規則へ切り替えません。元クライアントの送信元IPv4を使い、単一IP・CIDR・開始IP～終了IP、通常のタイプ指定、`any`、PTRのIPv4/CIDR、`edns=on/off`を扱います。EDNS省略時はヤマハの既定どおりoffです。

`edns=off`では上流向けのOPT（DOやオプションを含む）を除去します。DNSSEC関連・特別なEDNS要求をキャッシュしない方針は維持します。`edns=on`では既存OPTを保持し、OPTのない要求には空OPTを追加します。これにより、以前の固定設定の透明中継と応答内容が変わる場合があります。

`select ... reject` は該当する問い合わせを破棄します。PP/DHCPからの動的上流取得、`restrict pp`、NAT46、IPv6上流、`reject ptr`などの未対応構文を検出すると、設定全体の読み込みを失敗させて起動しません。最大256規則・異なる上流宛先16個までです。

配布版はRTXの静的登録名を起動時に読み取り、その名前への問い合わせを内蔵UDP DNSに渡します。親ドメインや子孫の名前までローカル扱いにはしません。ホスト名とIPの対応をLuaに複製して応答する処理は行いません。

開発・検証のために手動設定を使う場合の手順は、[開発・検証用の手動設定と一時実行](docs/development.md)にまとめています。通常の導入には不要です。

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
- `config/example.lua`：開発・検証専用のループバック限定・120秒の手動設定。
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
