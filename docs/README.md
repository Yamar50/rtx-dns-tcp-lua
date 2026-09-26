# 技術的な詳しい説明

[インストールと機能](../README.md) · [リリース一覧](https://github.com/Yamar50/rtx-dns-tcp-lua/releases)

導入するには[READMEのオンラインインストール](../README.md)をご覧ください。設定や仕組みを調べる場合は、目的に合う資料を選んでください。

## インストール・運用

| 調べたいこと | 資料 |
|---|---|
| インストール完了の確認、版の選択、自動起動の有無、失敗時の復旧 | [オンラインインストーラーの詳細](installer.md) |
| USBなどでの手動転送、DNS設定変更後の再起動、旧版からの更新 | [手動インストール・更新・再起動](install.md) |
| スクリプトと自動起動設定の削除 | [アンインストール](uninstall.md) |
| 起動しない・名前解決できない | [確認方法と不具合報告](install.md#起動しない名前解決できない場合) |

## 仕組み・対応範囲

| 調べたいこと | 資料 |
|---|---|
| 性能の目安、接続数・キャッシュ、設定の読取り、制限 | [技術概要](technical-overview.md) |
| 機種、最低ファームウェア、動作報告、インターフェース名 | [対応機種と実行環境](compatibility.md) |
| `dns server select`・PP・DHCPの選択順と状態更新 | [DNS設定の選択と定期更新](dns-policy.md) |
| IPv6のみの上流DNSが設定されている場合 | [IPv4 DNSへの切替仕様](dns-ipv6-fallback.md) |
| 現在の制約と過去版で修正した問題 | [既知の問題](known-issues.md) |
| ソースからのビルド、試験用設定、ファイル構成 | [開発・検証](development.md) |
| 変更したときに見直す文書・画像・Releaseの対応 | [文書の関連付けと更新手順](maintenance.md) |
| コードの生成方法、公開ソースとの照合 | [コードの来歴](code-provenance.md) |
| ライセンスと利用責任 | [ライセンスと免責事項](technical-overview.md#ライセンスと免責事項) |

## 検証記録

実機確認・協力者の報告・模擬試験を分け、試験した版と条件を記録しています。

| 内容 | 資料 |
|---|---|
| 機能試験・配備後確認の一覧 | [検証範囲](validation.md) |
| v0.9.9の負荷試験 | [既定制限と制限緩和時の結果](load-test-v0.9.9.md) |
| v0.1.3の負荷試験 | [過去版の結果](load-test-v0.1.3.md) |
| WebGUIからの導入・削除・再導入 | [WebGUIとアンインストーラー](results/webgui-uninstaller-2026-09-25.md) |
| バージョン固定・SHA256照合・復旧 | [バージョン別インストーラー](results/versioned-installer-2026-09-25.md) |
| 短縮したコマンド・進捗カウンター | [短縮コマンドと表示](results/short-bootstrap-2026-09-25.md) |
| 旧方式のインストーラー | [当時の検証記録](results/installer-2026-09-25.md) |

## バージョン別の変更内容

- [v0.9.9：機種・インターフェースの対応拡大とIPv4 DNSへの切替](releases/v0.9.9-details.md)
- [v0.1.4：レコード数の多い応答の送信タイムアウト修正](releases/v0.1.4-details.md)
- [v0.1.3：キャッシュ・TCP半閉鎖・DNSクラス処理の修正](releases/v0.1.3.md)
- [v0.1.2：PP・DHCPで取得するDNSと設定解析への対応](releases/v0.1.2.md)
- [NVR510試験版：協力者の報告と試験時の手順](releases/v0.1.4-nvr.1.md)
- [v0.9.9開発時の機種対応仕様と検証方針](compatibility-plan.md)

過去版の説明や試験手順は、その版の記録として残しています。現在の導入方法は[README](../README.md)を参照してください。
