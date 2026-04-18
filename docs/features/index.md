# 機能仕様 (Features)

Recerdo の機能レベル設計書（Feature Specification）一覧です。  
各ドキュメントはユースケース・シーケンス図・API設計・データモデルを含む詳細仕様書です。

---

<div class="grid cards" markdown>

-   :material-bell-outline: **通知機能**

    ---

    プッシュ通知・アプリ内通知の配信フロー、FCM連携、ユーザー設定管理。

    [:octicons-arrow-right-24: プッシュ通知配信](notifications/push-notification.md)

-   :material-toggle-switch-outline: **権限管理 / Feature Flag**

    ---

    段階的ロールアウト・Kill Switch・A/Bテストのフラグ管理仕様。

    [:octicons-arrow-right-24: Feature Flag 管理](permission/feature-flags.md)

-   :material-account-group-outline: **ソーシャル機能**

    ---

    旧友・旧グループとの再接続。組織メンバーシップを基盤とした接続モデル。

    [:octicons-arrow-right-24: ソーシャル接続](events/social-connections.md)

</div>

---

## 機能一覧

| カテゴリ | 機能 | ステータス | 設計書 |
|---------|------|----------|--------|
| 通知 | プッシュ通知配信 (FCM) | 🟡 提案 | [push-notification.md](notifications/push-notification.md) |
| 権限管理 | Feature Flag 管理 | 🟢 承認済み | [feature-flags.md](permission/feature-flags.md) |
| ソーシャル | ソーシャル接続 (Organization-based) | 🟢 承認済み | [social-connections.md](events/social-connections.md) |

## ステータス凡例

| アイコン | 意味 |
|---------|------|
| 🔵 草案 (Draft) | 初稿作成中 |
| 🟡 提案 (Proposal) | レビュー待ち |
| 🟢 承認済み (Approved) | 実装可能 |
| ⚫ 非推奨 (Deprecated) | 廃止予定 |

---

## 設計書の共通構成

各機能仕様書は以下のセクションで構成されています。

1. **概要** — 機能の目的・背景
2. **ユースケース詳細** — Who / What / When / Where / Why / How
3. **データモデル** — エンティティ定義・ER図
4. **API仕様** — エンドポイント・リクエスト/レスポンス
5. **シーケンス図** — フロー詳細（Mermaid）
6. **エラーハンドリング** — 異常系定義
7. **セキュリティ考慮** — 認可・データ保護
8. **テスト戦略** — ユニット・統合テスト方針
