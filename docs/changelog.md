# 変更履歴 (Changelog)

Recerdo Developer Docs の変更履歴です。  
各ドキュメントの最終更新日はページ下部にも表示されます。

---

## v0.4.0 — 2026-04-19

### 追加
- **機能仕様 (Features)** セクションのインデックスページを追加
- **ソーシャル接続** 機能仕様書を追加（`features/events/social-connections.md`）
- アーキテクチャ図を Mermaid 記法に変換（`index.md`, `clean-architecture/index.md`）
- ページ別最終更新日・作成日の表示を追加（`git-revision-date-localized`）
- Changelog ページを追加

### 修正
- Features タブクリック時にランダムなドキュメントが表示されるバグを修正（`features/index.md` が存在しなかった）
- Mermaid 図が表示されない問題を修正（JavaScript 初期化スクリプト追加）

---

## v0.3.0 — 2026-04-15

### 追加
- **プッシュ通知** 機能仕様書（`features/notifications/push-notification.md`）
- **Feature Flag 管理** 仕様書（`features/permission/feature-flags.md`）
- コアプラットフォーム PoC/Beta スコープ定義（`core/poc-beta-scope.md`）
- サーバーキャパシティ計画（`core/server-capacity-planning.md`）
- ファイアウォール & データプロテクション（`core/firewall-data-protection.md`）
- コストパフォーマンス分析（`core/cost-performance-analysis.md`）

### 変更
- MkDocs Material テーマに移行（Hugo から）
- 日本語検索対応（`lang: ja`）
- Netlify への自動デプロイ設定

---

## v0.2.0 — 2026-04-10

### 追加
- クリーンアーキテクチャ設計書 全サービス分（9ドキュメント）
  - API Gateway, Auth, Audit, Album, Events, Timeline, Storage, Notifications, Feature Flag
- マイクロサービス設計書 全サービス分（8ドキュメント）
- 5タブナビゲーション構成

---

## v0.1.0 — 2026-04-05

### 初期リリース
- API ドキュメント（Auth, Events, Album, Storage, Timeline, Audit）
- プロジェクト基本構成・README

---

!!! tip "ドキュメントの最終更新日について"
    各ページ下部に「最終更新: YYYY-MM-DD」が表示されます。  
    これは Git コミット履歴に基づく自動表示です。
