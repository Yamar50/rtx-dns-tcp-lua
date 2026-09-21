# コードの生成方法と公開ソースとの照合

調査日：2026-09-21

本プロジェクトの**ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した**。この開発方法の記載と、既存コードとの一致の有無は別の事項として確認した。

## 結果

調べた範囲では、既存のオープンソースソフトウェアからの特徴的なコード流用は確認できなかった。第三者コードの利用に伴う追加のライセンス表示が必要と特定できる箇所も見つからなかった。

この結論は、以下に記載する検索・比較・構成確認の範囲に限る。検索で一致が見つからないことは、流用がないことの証明ではない。

## 調査対象

初回公開時のコード本体の次の5ファイルを対象とした。SHA-256は調査対象の内容を識別するために記載している。

| ファイル | SHA-256 |
|---|---|
| `src/cache.lua` | `36f426784a8e9ef9da1e16f4384069f74722926b38046c35f6daa182dcb56343` |
| `src/dns_policy.lua` | `223e51e446b2f5c123c3c64a81adef22460779a55f12c91e50dfcef3d304a7ae` |
| `src/dns_wire.lua` | `5d24ddba419d53bf2e4d7bd44f8a036c96d3d0f5cb2842e3445a5a9a192023f2` |
| `src/main.lua` | `052f8db84dffec50cb083ad262e3a38a21d41ba6d31630edc3cc6362e7695450` |
| `src/relay.lua` | `28cea367bc4fa7e05f85abde64b80b12018aa0666f061d6dc5c79fa3a604dc73` |

各ファイルから短い特徴句・識別子を選んでWeb検索を行い、同分野の公開実装も読み比べた。ソース全文を外部のコード照合サービスへアップロードする方法は使用していない。

## 使用した検索句

引用句による検索8件と、比較対象を探す検索2件を実施した。

| 対象 | 検索句 |
|---|---|
| `dns_wire.lua` | `"compression pointer is not a prior name boundary"` |
| `dns_wire.lua` | `"invalid or excessively compressed name" lua` |
| `cache.lua` | `"entry exceeds cache TTL-field capacity"` |
| `cache.lua` | `"return tostring(#policy)" "cache_key"` |
| `relay.lua` | `"Relay:_choose_endpoint" "failed_endpoints"` |
| `relay.lua` | `"job.endpoint, job.upstream_id, job.state, job.selected_server"` |
| `dns_policy.lua` | `"reject PTR selection is unsupported"` |
| `main.lua` | `"dns_config must be omitted, running, or static"` |
| DNSの比較対象 | `Lua DNS resolver compression parser github openresty lua-resty-dns` |
| LRUの比較対象 | `Lua LRU cache doubly linked list github lua-resty-lrucache` |

最初の8検索で返された結果には、引用した特徴句に一致する公開コードは見つからなかった。一部の検索では、検索語を緩めた無関係な結果が返された。検索結果の有無だけで結論を出さず、次の実装を追加で確認した。

## 比較した公開実装

### OpenResty lua-resty-dns

[resolver.luaの原典](https://raw.githubusercontent.com/openresty/lua-resty-dns/master/lib/resty/dns/resolver.lua)を確認した。`bit`と`ngx` APIを使用するDNSリゾルバーであり、DNSヘッダ・ラベル・圧縮ポインタを処理する点は共通する。

本プロジェクトの`known_names`による名前境界の検証、正規化したwire形式、整数演算、応答の保存・再構築とは構造が異なる。目視した範囲で、特徴的なまとまったコードの一致は確認しなかった。

### OpenResty lua-resty-lrucache

[lrucache.luaの原典](https://raw.githubusercontent.com/openresty/lua-resty-lrucache/master/lib/resty/lrucache.lua)を確認した。LuaJIT FFIの構造体と、空きノード・使用中ノードのqueueを使用する。

本プロジェクトはLuaテーブルのノードを使用し、DNS応答の本文サイズとTTLフィールド数を個別に計数する。LRUの一般的な連結リスト操作という共通点はあるが、目視した範囲で特徴的なまとまったコードの一致は確認しなかった。

### starius/lua-lru

[lru.luaの原典](https://raw.githubusercontent.com/starius/lua-lru/master/src/lru/lru.lua)を確認した。純LuaのLRUキャッシュであり、件数とバイト数を制限する点は共通する。

この実装は配列添字によるtupleと関数closureを使用する。本プロジェクトの名前付きフィールド、DNS応答処理、TTL期限管理とは構造が異なる。目視した範囲で特徴的なまとまったコードの一致は確認しなかった。

## 同梱物と依存の確認

- 対象5ファイルには、第三者のCopyright・SPDX・ライセンス本文、または`copied from`・`derived from`・`adapted from`・`ported from`という出所表記はなかった。
- 対象5ファイルの`require`先は、本プロジェクト内のモジュールのみだった。実行にはルーターが提供するYamaha RTXのLua APIを使用する。
- 初回調査時の`tools/build.py`は本プロジェクトの5モジュールと明示された設定を結合する。外部コードをダウンロードしたり、外部ライブラリを生成物へ同梱したりする処理はない。
- `tools/build.py`と`tools/serve_artifact.py`はPython標準ライブラリのみを使用する。

出所表記がないこと自体は、第三者コードが使われていないことの証明にはならない。

## 調査の限界

本調査は、代表的な短いコード片のWeb検索、上記3実装との目視比較、同梱物・依存・出所表記の点検である。すべての公開ソース、検索対象外のソース、非公開コード、変形・翻訳されたコードを網羅していない。テストとドキュメントの全文について、同じ方法での外部ソース比較は行っていない。

この記録は、流用の不存在や権利関係を証明するものではなく、ソフトウェアのライセンスを付与するものでもない。特許については調査していない。

## 無編集で起動する配布版の追加確認

初回調査後、`auto_config.lua`を追加し、`main.lua`・`relay.lua`に自動設定の連携を追加した。これらもOpenAI Codexで生成した。IPv4などの共通処理は本プロジェクト内の実装と整合させている。ビルド時に結合する本体は6モジュールとなり、外部コードのダウンロードや同梱はない。

追加部分から次の3句を引用検索した。返された結果には検索語を緩めた無関係なページが含まれ、調べた範囲で引用句の一致は確認しなかった。新規モジュール全体の不存在証明ではない。

- `"automatic local DNS cannot select a router IPv4 address permitted by dns host"`
- `"automatic DNS ACL resolved to no permitted clients"`
- `"DNSRELAY automatic settings loaded ACL"`

配布版の本体SHA-256：

| ファイル | SHA-256 |
|---|---|
| `src/auto_config.lua` | `9616cf8b8533f2ea88384700db3f02d952b93aebe759dd98c3503189b5589d8b` |
| `src/cache.lua` | `36f426784a8e9ef9da1e16f4384069f74722926b38046c35f6daa182dcb56343` |
| `src/dns_policy.lua` | `223e51e446b2f5c123c3c64a81adef22460779a55f12c91e50dfcef3d304a7ae` |
| `src/dns_wire.lua` | `5d24ddba419d53bf2e4d7bd44f8a036c96d3d0f5cb2842e3445a5a9a192023f2` |
| `src/main.lua` | `61fb3dbb25a03c665b5f7a916fc08de382b67d75de8f184ae0ad91aa2181b7b9` |
| `src/relay.lua` | `ff5eed254f3866ff97f79d4f9ba4cfb49c52be8297b1501b278c03101dd28c31` |

配布用`config/release.lua`には、ネットワークのIPアドレス・個別ホスト名・認証情報を含めていない。アクセス許可とローカル登録名は実行するRTXのconfigから起動時に取得し、設定全文をログ出力しない。
