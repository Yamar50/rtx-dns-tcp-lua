# 過去のバージョン

[最新版のインストールと機能](../../README.md) · [技術資料一覧](../README.md)

ソースコード・テスト・ドキュメントはすべてOpenAI Codexで生成した。

現在の配布版は[v1.0.0](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v1.0.0)です。このページは過去版の変更内容・配布物・試験記録への案内です。過去の説明と試験結果は、その版の記録として残しています。

| バージョン | 主な変更 | 説明・試験記録 |
|---|---|---|
| [v0.9.9](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.9.9) | 機種とインターフェースの対応拡大、IPv6のみの規則からIPv4 DNSへの切替 | [詳細](v0.9.9-details.md)・[機能試験](../validation.md#v099-validation)・[負荷試験](../load-test-v0.9.9.md) |
| [v0.1.4](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.4) | レコード数の多い応答で送信前に接続が閉じる問題を修正 | [詳細](v0.1.4-details.md)・[修正後の試験](../validation.md#v014-validation) |
| [v0.1.4-nvr.1](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.4-nvr.1) | NVR510のONUインターフェースに対応する試験版 | [試験版の説明と協力者の報告](v0.1.4-nvr.1.md) |
| [v0.1.3](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.3) | キャッシュ判定、TCP半閉鎖、DNSクラス制限を修正 | [説明](v0.1.3.md)・[負荷試験](../load-test-v0.1.3.md) |
| [v0.1.2](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.2) | PP・DHCPで取得するDNSと、DNS選択規則の解析に対応 | [説明と検証結果](v0.1.2.md) |
| [v0.1.1](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.1) | 送信元IPごとのTCP接続数・問い合わせ数制限を追加 | [当時のソースと説明](https://github.com/Yamar50/rtx-dns-tcp-lua/tree/v0.1.1) |
| [v0.1.0](https://github.com/Yamar50/rtx-dns-tcp-lua/releases/tag/v0.1.0) | TCP DNS補完、接続再利用、キャッシュ、自動設定の初回公開版 | [当時のソースと説明](https://github.com/Yamar50/rtx-dns-tcp-lua/tree/v0.1.0) |

v0.9.9以前では、PP・DHCPの取得状態を更新する機能とconfigの読込みを区別していました。DNS関連のconfigを変更した後はスクリプトの手動再起動が必要です。v1.0.0で追加した[設定の自動再読込](../config-reload.md)は、過去版の配布ファイルには含まれません。

過去版で確認した問題と修正状況は[既知の問題](../known-issues.md)、機種ごとの使用版は[動作確認状況](../compatibility.md)を参照してください。新しい版の実装を、過去の配布物や試験記録へ遡って適用することはありません。

[GitHubのRelease一覧](https://github.com/Yamar50/rtx-dns-tcp-lua/releases)

## 過去版のオンラインインストール

次のコマンドは当時の配布物を導入します。最新版への更新には[README](../../README.md)のv1.0.0用コマンドを使用してください。

<a id="version-v014"></a>

### v0.1.4をインストール

<!-- INSTALLER_COMMAND_V014_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/bd9762874861d7e0e71b9dcdeba3cfc0c1a4843e/installer/versions/v0.1.4/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==25773,"Installer download failed");assert(loadstring(r.body))(DNSINSTALL_BOOT,"v0.1.4")'
```
<!-- INSTALLER_COMMAND_V014_END -->

<a id="version-v099"></a>

### v0.9.9をインストール

<!-- INSTALLER_COMMAND_V099_START -->
```text
lua -e 'local DNSINSTALL_BOOT="yes";local r=rt.httprequest({url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/bd9762874861d7e0e71b9dcdeba3cfc0c1a4843e/installer/versions/v0.9.9/rtx-dns-install.lua",method="GET",timeout=30});assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body==25773,"Installer download failed");assert(loadstring(r.body))(DNSINSTALL_BOOT,"v0.9.9")'
```
<!-- INSTALLER_COMMAND_V099_END -->

