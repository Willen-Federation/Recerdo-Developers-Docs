# 変更履歴 (Changelog)

Recerdo Developer Docs の変更履歴です。  
各ドキュメントの最終更新日はページ下部にも表示されます。

---

## v0.5.0 — 2026-04-19

### 追加（Notion レビューコメント反映・2026-04-18）

- **[デプロイメント戦略](core/deployment-strategy.md)**: Beta（セルフホストVPS+レンタル）→ 本番（OCIファースト）への段階的移行戦略。AWS Cognito/SES は継続利用し、コンピュート・ストレージは OCI 安価シェイプへ。
- **[環境抽象化 & Feature Flag](core/environment-abstraction.md)**: ハードコード排除のための3層切替設計（環境変数 / Feature Flag / DI アダプタ）。12-factor 準拠。
- **[キュー抽象化設計](microservice/queue-abstraction.md)**: SQS 一択を撤回し、BullMQ / Sidekiq / RabbitMQ / NATS / OCI Queue / SQS を Port & Adapter で差し替え可能に。Beta は Redis+BullMQ、本番は OCI Queue を第一推奨。
- **[Admin Console Service（MS）](microservice/admin-console-svc.md)**: 管理者コンソールを独立マイクロサービスとして新設。RBAC・二段階承認・成り代わり・コマンドキューを含む。
- **[Admin Console Service（CA）](clean-architecture/admin-console-svc.md)**: クリーンアーキテクチャ準拠のレイヤ別実装ガイド（Entity / UseCase / Adapter / Framework）。Next.js / Rails ハイブリッド UI に対応。

### 変更

- `microservice/index.md`: 「メッセージング: SQS/SNS」の記述を「キュー抽象化レイヤー経由」に刷新、BetaとProdの技術スタックを2列比較で記載。
- `mkdocs.yml`: 新規ドキュメント5件を nav に追加。
- `clean-architecture/index.md`: Notifications / Feature Flag / Admin Console の3件を設計書一覧に追加。

### 対応 Notion コメント

- 「システム全体でSQSを採用するようにしているが、Oracleや自前のバッジ処理などで利用する場合などを複数検討した上で、システムを提案するように」→ キュー抽象化設計で対応。
- 「AWSを基本としつつ、OracleCloudなど安価なクラウドを利用予定」→ デプロイメント戦略で OCI ファーストを明記。
- 「Beta版はセルフホスティング（VPS+レンタルサーバー）」→ ストレージ層（レンタル）と計算層（VPS）の分離構成を図示。
- 「Beta→本番でシステムの改修が大変にならないように、FeatureFlagやソフト変更で対応」→ 環境抽象化ドキュメントで3層切替を定義。
- 「管理者コンソール設計が行われていません。マイクロサービス・クリーンアーキテクチャベースで」→ Admin Console を新規マイクロサービスとして MS/CA 両面で設計。

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
