ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

# DNS設定の選択と定期更新

このページはv0.9.9候補版の実装を説明します。v0.1.4から、[IPv6のみの規則を除外して後続select・通常DNSのIPv4を使う処理](dns-ipv6-fallback.md)と、機種ごとのインターフェース名の共通解析を追加しています。

| 設定・状態 | 動作 |
|---|---|
| `dns service recursive` / `off` | recursiveで開始、offなら起動を中止。省略時はrecursive |
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
| configそのものの変更 | スクリプトの再起動が必要 |

## DNS未取得と代替IP

PP/DHCPのDNSが明確に未取得で、select行に代替IPがあれば、そのIPを使います。マニュアルの`default-server`は引数名であり、コマンドに書くキーワードではありません。例:

```text
dns server select 10 pp 1 edns=on 192.0.2.53 edns=off any example.test
dns server select 20 dhcp lan2 edns=on 192.0.2.54 edns=on any .
```

代替IPがない場合、DHCP未取得は通常のDNS設定で解決し、PP未取得はSERVFAILです。LuaがPPの接続・切断を操作することはありません。取得元不明、状態取得失敗、IPv6のみの取得は「未取得」と区別し、代替IPへ逃がしません。通信失敗時の再試行は選択した規則内だけで行います。

RTX1210 Rev.14.01.42の内蔵DNSでは、DHCP未取得時に行内の代替IPより通常の固定DNSを使うケースを確認しました。このスクリプトは、その挙動を再現せず、現行公式マニュアルの明示的な代替IPを使用する仕様に合わせています。

## 未対応設定の扱い

複数のIPv4 DHCPインターフェースについて、`show status dhcpc`の共通DNSだけでは指定IFの取得DNSを特定できません。そのため推測で使用せず、該当する問い合わせをSERVFAILにします。無関係な規則の問い合わせは継続します。

TCP通信はIPv4です。AAAAレコードもIPv4上流で問い合わせできます。同じ規則に利用できるIPv4候補があれば使い、IPv6のみと確定したselect規則だけを除外して後続規則と通常DNSを調べます。NAT46による変換が必要な規則、取得元・条件が不明な規則は読み飛ばさずSERVFAILです。

NVRの`dns server select ... pdp wan1 ...`はPDP取得を行わず、解釈できた条件に一致する問い合わせをSERVFAILにします。他の条件の規則は継続します。通常の`dns server pdp wan1`は、固定DNSやPPがある場合はそれらに優先権を譲り、それらがなければ未対応のPDPを選択状態として保持します。下位DHCPへ黙って変更しません。構文の境界まで不明な取得元は、条件を推測せず扱います。

既知の条件を評価できる規則は、その条件に該当する問い合わせだけを失敗させます。未知の構文で条件を確定できない場合は、その規則番号で該当する可能性のある問い合わせを止めます。重複・不正な規則番号、壊れた入力、上限超過、不明なACLは起動エラーです。`show config`のスナップショットを読み、`no`コマンドの操作履歴を適用する機能はありません。

動的取得の結果、起動後に上流宛先数の上限16個を超えた場合は、スクリプトを終了せず、転送規則を一時的に利用不可にします。次回以降の更新で上限内に戻れば回復します。起動時に上限を超えている場合は起動エラーです。

## インターフェースと内蔵DNS

名前は`lanN`・`lanN/M`・`lanN.M`・`vlanN`・`wan1`・`onu1`・`bridge1`の7形式で分類し、PPは`pp N`として別に処理します。DHCP取得元と直接の`dns host`には`lanN.M`を含めません。状態・自機アドレスの読取り、および`dns host lan`のLAN集合ではLAN分割のアドレスも扱います。[用途別の対応](compatibility.md#interface-forms)

`dns host lan`はLAN・タグVLAN・LAN分割・VLAN・bridgeの明示した集合で評価し、WAN・ONUを含めません。許可に使うアドレスや構文が不明なら起動を中止し、推測で許可範囲を広げません。参照していないインターフェースの読めないアドレスや重複は、選択したACLに影響しない限り無視します。

簡易DNSの登録名は内蔵DNSへUDPで問い合わせます。この経路の受信上限は2,048バイトです。EDNSがある場合は広告サイズが2,048を超えるときだけ縮小し、EDNSなしの要求へは追加しません。DO/CD・ID・質問・EDNSオプションを保持します。不完全なDNS応答やTC=1の応答はSERVFAILにし、ローカル名を外部DNSへ転送しません。外部上流から受けるTCP応答の上限65,535バイトとは別の制限です。

## AAAAフィルター

外部TCP経路では元クライアントの送信元でDNSを選び、QTYPE=AAAAの応答にフィルターを適用します。AAAAと同じowner/classのAAAA対象RRSIGを除去し、CNAME/DNAMEなどは名前圧縮を展開して再構築します。加工した応答のADをクリアし、キャッシュには保存しません。AAAA不存在を証明するDNSSEC署名を生成する機能ではありません。未知RRなどを安全に再構築できなければ、その問い合わせはSERVFAILです。

NXDOMAIN・SERVFAILや、AAAA除去が不要な応答は、通常のEDNS処理を除き維持します。ANY応答全体からAAAAを除く機能ではありません。簡易DNSの登録名は既存の内蔵UDP経路を維持します。

参照: [DNS設定の優先順位](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_chapter.html)、[dns server select](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server_select.html)、[dns server dhcp](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_server_dhcp.html)、[AAAAフィルター](https://www.rtpro.yamaha.co.jp/RT/manual/rt-common/dns/dns_service_aaaa_filter.html)。
