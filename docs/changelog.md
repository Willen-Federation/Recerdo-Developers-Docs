# 変更履歴 (Changelog)

Recuerdo Developer Docs の変更履歴です。  
各ドキュメントの最終更新日はページ下部にも表示されます。

---

## v0.6.2 — 2026-04-19 (追加設計プラン反映・レビュー指摘反映)

### 変更

- **`core/policy.md`**: 大規模類似サービスモデルを参照した「追加設計プラン」を新設。設計・分析・課題・他者レビュー反映の反復手順を明文化。
- **`core/index.md`**: 追加設計プランの参照導線を追加し、横断ドキュメント更新フローを明記。
- **`microservice/index.md`**: 追加設計プラン反映テーブルと横断レビュー観点を追加。
- **`clean-architecture/index.md`**: クリーンアーキテクチャ層への反映方針（Push-first、DLQ、TLS要件）を追記。
- **`microservice/notifications-svc.md`**: メール通知条件アンカーを安定化（`#mail-notification-conditions`）し、追加設計プランとレビュー反映内容を追記。
- **`clean-architecture/notifications-svc.md`**: PostfixSMTPAdapter の実装例を整理し、STARTTLS 必須・TLS1.2+・AUTH 非対応時エラーの記述へ統一。重複していたサンプル断片を削除。

### 検証

- `mkdocs build --strict` でビルド成功。

---

## v0.6.1 — 2026-04-19 (ポリシー適用・最終クリーンアップ)

### 追加

- **[Permission API](api/permission.md)**: `/api/auth/sessions/*` / `/api/auth/tokens/*` / `/api/auth/permissions/*` / `/api/auth/roles/*` の HTTP API 仕様を新規追加。`api/index.md` から参照されていた未存在リンクを解消。
- mkdocs.yml ナビゲーションに「権限 (Permission)」を追加。

### 変更（旧システム記述の削除）

- **`core/cost-performance-analysis.md`**: AWS SES / ECS Fargate / RDS / Aurora / CloudFront を推奨していた旧構成を全面改訂。Beta=XServer VPS + CoreServerV2 + Garage + Postfix、本番=OCI ファースト の新ポリシーに統一。§9「採用／不採用の理由」ポリシー対照表を追加。
- **`core/deployment-strategy.md`**: Mermaid 図の MinIO ノードを Garage へ。k3s 参照を Docker Compose / OCI Container Instances / OKE へ。`#### TODO` を Postfix 方針に解決。
- **`core/server-capacity-planning.md`**: スケールアウト閾値の "S3 + CloudFront"・"ECS Fargate + RDS" を OCI ベースに改訂。
- **`core/poc-beta-scope.md`**: 移行ロードマップの "VPS → ECS Fargate" を "VPS → OCI Compute A1.Flex / OKE" に改訂。
- **`core/environment-abstraction.md`**: `*_PROVIDER` 環境変数の記述に「AWS 系アダプタは未実装（Cognito のみ採用）」を明記。
- **`api/auth.md` / `api/events.md` / `api/storage.md`**: 全ての `#### TODO` / `##### TODO` ヘッダーを削除。各 TODO は既存の仕様テキストで解決済みのため、見出しのみを除去。
- **`clean-architecture/events-svc.md` / `clean-architecture/notifications-svc.md`**: TODO セクションを QueuePort / NotificationPort / Postfix SMTP の具体仕様に置換。
- **`microservice/album-svc.md` / `clean-architecture/album-svc.md`**: 「ハイライトビデオ自動生成」表記をすべて「ユーザー選択による連結（`media_ids[]` 必須、ML 推薦なし）」に統一。

### 検証

- `grep -rn "TODO\|FIXME" docs/` → `changelog.md` の履歴記述のみ。
- `grep -rn "ECS Fargate\|Aurora\|RDS\|CloudFront\|MinIO" docs/` → すべて「不採用」「比較表」「採用しない」文脈のみ。
- `grep -rn "自動生成" docs/.../album-svc.md` → すべて「自動生成は行わない」の否定文脈のみ。
- 内部リンク切れ 0 件。

---

## v0.6.0 — 2026-04-19 (ポリシー適用)

### 変更（インフラ／メディア方針の一括適用）

- **AWS は Cognito のみ** に限定。他のAWSサービス（SQS / SNS / SES / S3 / Lambda / CloudWatch 等）の記述を全ドキュメントから除去し、OSS / OCI プロダクトへ置き換え。
- **Beta 構成**: XServer VPS（6 core / 10 GB） + CoreServerV2 CORE+X（6 GB）/ **Garage（S3互換OSS）** / **MySQL（MariaDB互換）** / **Redis + BullMQ・asynq** / **Postfix + Dovecot + Rspamd**。
- **本番**: OCI ファースト（OCI Object Storage / MySQL HeatWave / Queue / Cache with Redis）。メールは CoreServerV2 CORE+X 継続。
- **Feature Flag: Flipt** / **ログ: Loki** / **プッシュ: FCM** を明文化。
- **メディアパイプライン**（`api/storage.md`, `api/album.md`）: 動画 → HLS（360p/720p/1080p・6秒セグメント）、HEIC → JPEG/WebP（libheif）、Live Photo → 画像+動画ペア（Apple `asset_identifier`）。`variants`（`hls_master_url` / `image_url` / `live_photo_video_url` 等）を API レスポンスに追加。
- **ハイライト動画**: 自動生成を廃し、`media_ids[]` を必須とするユーザー選択方式に統一（`storage.md` / `album.md`）。
- **Storage 削除ポリシー**: 論理削除 + 30日保持 → 物理パージ（原本 + 派生）。
- **Auth API**: `#### TODO` を解消。Cognito（AuthN）+ Permission Service（AuthZ）+ JWKS 検証 の具体仕様に置換。
- **Events API**: 4件の TODO を具体仕様化。
    - 招待: 8文字大小区別なし Slug + QR + JWT（TTL 1時間, ワンタイム, 再発行可）+ FCM/Postfix SMTP 通知。
    - アーカイブ: 論理 → 2年保持 → コールド（Garage / OCI Archive） → 7年で物理削除。
    - コメント: 論理削除・15分以内編集履歴・メディア添付・メンション対応。
    - リアクション: `{❤️, 😂, 🎉, 😢, 👏, 🔥}` 固定、Redis INCR + Timeline ファンアウト。
- **Audit API**: "S3 archival" → "オブジェクトストレージアーカイブ" に改名、階層保管ポリシーを明記。
- **Timeline / Features / Notifications / Feature Flag**: SQS・SNS・CloudWatch・Lambda 参照を除去し、Queue 抽象化 / Prometheus+Loki / Alertmanager ベースへ置換。
- `index.md`: アーキテクチャ Mermaid 図を Cognito・Permission・Queue・Object Storage 構成に刷新。ポリシーサマリを追加。
- 対象ページに `最終更新: 2026-04-19 ポリシー適用` フッターを付与。

---

## v0.5.0 — 2026-04-19

### 追加（Notion レビューコメント反映・2026-04-18）

- **[デプロイメント戦略](core/deployment-strategy.md)**: Beta（セルフホストVPS+レンタル）→ 本番（OCIファースト）への段階的移行戦略。AWS Cognito を継続利用し、コンピュート・ストレージは OCI 安価シェイプへ。（注: この時点では SES も併用案として記載していたが、v0.6.0 で Postfix+Dovecot+Rspamd 自前運用へ改定。）
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
