ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

# DNS設定の選択と定期更新

[インストールと機能](../README.md) · [技術資料一覧](README.md)

このページは正式版v1.0.1の実装を説明します。v0.9.9の[IPv6のみの規則を除外して後続select・通常DNSのIPv4を使う処理](dns-ipv6-fallback.md)とインターフェース名の共通解析、およびv1.0.0の[DNS設定の自動再読込](config-reload.md)を引き継いでいます。

| 設定・状態 | 動作 |
|---|---|
| `dns service recursive` / `off` | recursiveで開始。offではTCP待受を停止して設定確認を続け、recursiveに戻れば復帰。省略時はrecursive |
| `dns service fallback on/off` | 受け入れ。Luaの中継先選択には使用しない |
| `dns server select` | 番号順。固定IP・PP・DHCP・reject、問い合わせタイプ・名前・元クライアントIPv4・`restrict pp`を評価 |
| 通常のDNS設定 | 固定`dns server`、`dns server pp`、NVRの`dns server pdp`、`dns server dhcp`の優先順。PDP取得は未対応。PP未取得やPDP未対応を理由に下位DHCPへ変更しない |
| PP取得DNS | 指定PPが接続中で、IPCP Localの通知DNSを確認できた場合に使用 |
| IPv4 DHCP取得DNS | configとstatusで取得元を一意に確定できる場合だけ共通DNS情報を使用。同じIFのprimary/secondaryは同一取得元 |
| DHCPv6取得DNS | 指定IFのclient側情報を解析。選択規則の取得IPがIPv6のみなら後続の一致select、次に通常DNSのIPv4を使う。IPv6通信は行わない |
| 未対応の取得元 | 条件を解析できる規則は、その条件に一致する問い合わせのみSERVFAIL。未知の取得元を理由に全体を停止しない |
| `restrict pp N` | NがDOWNなら条件不一致。状態不明は該当する可能性のある問い合わせをSERVFAIL |
| `reject ptr` | IPv4単一アドレス・プレフィックスに一致するPTRを破棄 |
| 実際に使用する取得DNS・選択条件の変更 | 30秒ごとの確認で変化を検出したら、全上流接続・キャッシュを破棄。ローカルUDP経路を含む処理中の問い合わせはSERVFAILで終了 |
| configのDNS関連設定の変更 | 約30秒ごとに確認。関連設定が変わったら既存接続・キャッシュを破棄し、同じLuaタスク内で初期化。手動再起動は不要 |
| 関連設定に変更なし | 接続・キャッシュを維持 |
| 設定取得失敗・初期化できない設定 | 古い設定によるTCP待受を停止。次回の設定確認で再試行 |

## DNS未取得と代替IP

`show status pp N`の現在の状態と`IPCP Local`を解析します。`Primary-DNS(...)`・`Secondary-DNS(...)`が通知されていればそのアドレスを使います。英語・CP932の実測表示とUTF-8の互換入力に対応し、過去の接続履歴を現在の状態として読みません。

| 選択した取得元の状態 | v1.0.1の動作 |
|---|---|
| PP接続中・通知DNSあり | 通知DNSを使う |
| PP切断／無効・`restrict pp N`の条件不一致 | 次のselect規則を評価する |
| PP切断／無効・`restrict`なし | 選択を維持し、宛先がなければSERVFAIL |
| PP接続処理中、状態不明、IPCP欄の欠損・矛盾 | 必要な状態を確定できない問い合わせはSERVFAIL |
| PP接続中・完全なIPCP欄に通知DNSなし | 通常の固定`dns server`のIPv4へ直接切替。後続selectは調べず、利用できなければSERVFAIL。下記のEDE注記を追加する |
| DHCPのIPリースなし、または1取得元の共通情報からDNS通知なしを確認 | 行内代替IPより通常DNSを使用する。後続selectは再検索しない |
| DHCP取得元・状態を特定できない | 該当する問い合わせはSERVFAIL。推測で別のDNSへ送らない |

行内代替IPは、`dns server select 10 pp 1 192.0.2.53 any .`の`192.0.2.53`です。公式の`default-server`は引数名で、コマンドに書くキーワードではありません。内蔵DNSは接続時に有効だったPPの行内代替IPを保持することがありますが、現在のconfigや`show status pp`には保持先が出ません。そのため、通知DNSがない場合に現在の行内IPを有効な宛先と推測することをやめ、通常固定DNSを使う例外を追加しました。[内蔵DNSとの比較と仕様](dns-select-native-compatibility.md)

この例外は「通知DNSなし」を確認できたPP接続中だけに適用します。通信障害、解析不能、DHCP取得元不明、明示拒否には適用しません。選択したIPv4 DNSがSERVFAIL・無応答・TCP非対応でも、別の規則や通常DNSへ問い合わせ直しません。LuaがPPの接続・切断を操作することもありません。

DHCPのIPリースあり・共通情報あり・DNS通知なしはRTX1210の1取得元で実測しました。複数IFへの取得DNSの対応付け、共通情報の省略、他機種・他IF形式には未確認の範囲があります。[対応範囲と残る制約](known-issues.md)を参照してください。

### PPの代替経路を使った応答の注記

通常固定DNSへ切り替えた理由を、EDNS付き要求への応答にEDE（オプション15、情報コード0）として付加します。

```text
rtx-dns: select:2 PP DNS destination unavailable; used configured dns server; answer may differ.
```

規則2（`dns server select 2`）の例です。NOERROR・NXDOMAIN等のRCODEや回答は保持します。固定DNSでも応答を取得できない場合は、失敗を説明するEDE付きSERVFAILになります。ブラウザーに警告を出す機能ではなく、EDE表示に対応する`dig`等で調べるための情報です。

クライアントがEDNSを使っていない、追加後に65,535バイトを超える、既存OPTが末尾にない等の場合は注記を省略して回答を優先します。上流の`edns=off`とクライアントのEDNSは別に扱います。省略時を含め、経路ごとに頻度を制限したログを残します。IPアドレス・問い合わせ名・認証情報は注記に含めません。

キャッシュには注記を付ける前の回答を保存し、応答時にその要求と選択経路に合わせて注記します。PPの通知DNSが戻る等、選択状態が変わった場合は既存のキャッシュ・接続を破棄します。[EDEの根拠：RFC 8914](https://www.rfc-editor.org/rfc/rfc8914.html#section-2)

## 未対応設定の扱い

複数のIPv4 DHCPインターフェースについて、`show status dhcpc`の共通DNSだけでは指定IFの取得DNSを特定できません。そのため推測で使用せず、該当する問い合わせをSERVFAILにします。無関係な規則の問い合わせは継続します。

TCP通信はIPv4です。AAAAレコードもIPv4上流で問い合わせできます。同じ規則に利用できるIPv4候補があれば使い、IPv6のみと確定したselect規則だけを除外して後続規則と通常DNSを調べます。NAT46による変換が必要な規則、取得元・条件が不明な規則は読み飛ばさずSERVFAILです。

NVRの`dns server select ... pdp wan1 ...`はPDP取得を行わず、解釈できた条件に一致する問い合わせをSERVFAILにします。他の条件の規則は継続します。通常の`dns server pdp wan1`は、固定DNSやPPがある場合はそれらに優先権を譲り、それらがなければ未対応のPDPを選択状態として保持します。下位DHCPへ黙って変更しません。構文の境界まで不明な取得元は、条件を推測せず扱います。

既知の条件を評価できる規則は、その条件に該当する問い合わせだけを失敗させます。未知の構文で条件を確定できない場合は、その規則番号で該当する可能性のある問い合わせを止めます。重複・不正な規則番号、壊れた入力、上限超過、不明なACLでは初期化できないためTCP待受を停止し、約30秒ごとに再試行します。`show config`のスナップショットを読み、`no`コマンドの操作履歴を適用する機能はありません。

動的取得の結果、起動後に上流宛先数の上限16個を超えた場合は、スクリプトを終了せず、転送規則を一時的に利用不可にします。次回以降の更新で上限内に戻れば回復します。初期化時に上限を超えている場合はTCP待受を開始せず、次回の設定確認で再試行します。

## インターフェースと内蔵DNS

名前は`lanN`・`lanN/M`・`lanN.M`・`vlanN`・`wan1`・`onu1`・`bridge1`の7形式で分類し、PPは`pp N`として別に処理します。DHCP取得元と直接の`dns host`には`lanN.M`を含めません。状態・自機アドレスの読取り、および`dns host lan`のLAN集合ではLAN分割のアドレスも扱います。[用途別の対応](compatibility.md#interface-forms)

`dns host lan`はLAN・タグVLAN・LAN分割・VLAN・bridgeの明示した集合で評価し、WAN・ONUを含めません。許可に使うアドレスや構文が不明ならTCP待受を停止して設定確認を続け、推測で許可範囲を広げません。参照していないインターフェースの読めないアドレスや重複は、選択したACLに影響しない限り無視します。

簡易DNSの登録名は内蔵DNSへUDPで問い合わせます。この経路の受信上限は2,048バイトです。EDNSがある場合は広告サイズが2,048を超えるときだけ縮小し、EDNSなしの要求へは追加しません。DO/CD・ID・質問・EDNSオプションを保持します。不完全なDNS応答やTC=1の応答はSERVFAILにし、ローカル名を外部DNSへ転送しません。外部上流から受けるTCP応答の上限65,535バイトとは別の制限です。

## AAAAフィルター

外部TCP経路では元クライアントの送信元でDNSを選び、QTYPE=AAAAの応答にフィルターを適用します。AAAAと同じowner/classのAAAA対象RRSIGを除去し、CNAME/DNAMEなどは名前圧縮を展開して再構築します。加工した応答のADをクリアし、キャッシュには保存しません。AAAA不存在を証明するDNSSEC署名を生成する機能ではありません。未知RRなどを安全に再構築できなければ、その問い合わせはSERVFAILです。

NXDOMAIN・SERVFAILや、AAAA除去が不要な応答は、通常のEDNS処理を除き維持します。ANY応答全体からAAAAを除く機能ではありません。簡易DNSの登録名は既存の内蔵UDP経路を維持します。

参照: [DNS設定の優先順位](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_chapter.html)、[dns server select](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server_select.html)、[dns server dhcp](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server_dhcp.html)、[AAAAフィルター](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_service_aaaa_filter.html)。
