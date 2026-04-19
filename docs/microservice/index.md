# マイクロサービス設計

Recerdoのバックエンドは、責務ごとに分離されたマイクロサービスで構成されています。各サービスは独立してデプロイ可能で、**キュー抽象化レイヤー**（[キュー抽象化設計](queue-abstraction.md)）を介した非同期メッセージングで連携します。実装は Beta では **Redis + BullMQ / asynq**、本番では **OCI Queue Service** に差し替わります（コード変更なし、Feature Flag + 環境変数で切替）。

## サービス一覧

| サービス名                                    | リポジトリ名               | 主な責務                                                | ステータス |
| --------------------------------------------- | -------------------------- | ------------------------------------------------------- | ---------- |
| [Authentication Service](auth-svc.md)         | recuerdo-auth-svc          | 認証・JWT・セッション管理                               | Draft      |
| [Audit Service](audit-svc.md)                 | recuerdo-audit-svc         | 監査ログ・コンプライアンス                              | Draft      |
| [Album Service](album-svc.md)                 | recuerdo-album-svc         | アルバム・写真・メモリ管理                              | Draft      |
| [Events Service](events-svc.md)               | recuerdo-events-svc        | イベント・通知・リアクション                            | Draft      |
| [Timeline Service](timeline-svc.md)           | recuerdo-timeline-svc      | タイムライン・フィード生成                              | Draft      |
| [Storage Service](storage-svc.md)             | recuerdo-storage-svc       | オブジェクトストレージ・メディア管理・HLS変換・HEIC変換 | Draft      |
| [Notification Service](notifications-svc.md)  | recuerdo-notifications-svc | Push / Email 配信                                       | Draft      |
| [Feature Flag System](feature-flag-system.md) | recuerdo-feature-flag-svc  | Feature Flag・段階的ロールアウト                        | Approved   |
| [Admin Console Service](admin-console-svc.md) | recuerdo-admin-console-svc | 運用・モデレーション・管理者コンソール                  | Draft      |

## 横断基盤ドキュメント

| ドキュメント                             | 概要                                                                                         |
| ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| [キュー抽象化設計](queue-abstraction.md) | OSSキュー（Redis+BullMQ / asynq）とマネージド（OCI Queue）を差し替え可能にする抽象化レイヤー |

## サービス間通信

```
API Gateway
    ├── auth-svc          ← 認証・トークン検証
    ├── album-svc         ← アルバム操作
    ├── events-svc        ← イベント管理
    ├── timeline-svc      ← フィード取得
    ├── storage-svc       ← メディアアップロード
    └── admin-console-svc ← 管理者コンソール・モデレーション

各サービス → audit-svc            (Queue Port 経由で監査ログ送信)
auth-svc   → events-svc           (Queue Port: トークン無効化通知)
admin-*    → feature-flag-svc     (Flag 変更・Kill Switch)
全 Write 系 → feature-flag-svc     (評価問い合わせ、毎リクエスト)
```

## テクノロジースタック（環境別）

| 項目           | Beta（セルフホスト）                                             | 本番（OCIファースト）                |
| -------------- | ---------------------------------------------------------------- | ------------------------------------ |
| 言語           | Go 1.22+ / Ruby 3.3+（Admin Rails 版）                           | 同左                                 |
| フレームワーク | Echo / Gin / Rails 8                                             | 同左                                 |
| データベース   | MySQL 8.0 / MariaDB 10.11（XServer VPS、MariaDB 互換性をテスト） | OCI MySQL HeatWave                   |
| キャッシュ     | Redis 7.x（XServer VPS 共用）                                    | OCI Cache with Redis                 |
| メッセージング | **Redis + BullMQ** (Node) または **asynq** (Go)                  | **OCI Queue Service**                |
| ストレージ     | Garage（S3互換 OSS, CoreServerV2 CORE+X）                        | OCI Object Storage                   |
| メール         | Postfix + Dovecot + Rspamd（CoreServerV2）                       | 同左（CoreServerV2 継続利用）        |
| Push           | FCM (Firebase Cloud Messaging)                                   | 同左                                 |
| 認証           | AWS Cognito + JWT (RS256)                                        | 同左                                 |
| Feature Flag   | Flipt + OpenFeature                                              | 同左                                 |
| メディア変換   | FFmpeg (HLS) / libheif (HEIC)                                    | 同左（OCI Container Instances 実行） |
| 監視ログ       | Prometheus + Loki + Grafana                                      | 同左                                 |
| コンテナ       | Docker Compose / k3s                                             | OCI Container Instances              |
| IaC            | Terraform                                                        | 同左（プロバイダのみ切替）           |

すべての差分は **Feature Flag + 環境変数** で切替可能（[環境抽象化](../core/environment-abstraction.md) 参照）。AWS サービスは **Cognito のみ** 利用し、SQS / SES / S3 / DynamoDB / RDS / MinIO / EC2 / EKS / ElastiCache / Lambda / CloudFront は採用しない（[基本的方針（ポリシー）](../core/policy.md) 参照）。

## 追加設計プラン反映（大規模類似サービスモデル準拠）

| 反映テーマ | 変更対象 | 更新内容 |
| --- | --- | --- |
| 通知設計の再定義 | notifications-svc | Push-first、Email 条件付き、STARTTLS 必須の運用前提を明確化 |
| 非同期処理の共通化 | 全サービス | QueuePort + 冪等 + DLQ 監査の統一運用モデルを採用 |
| レビュー駆動改善 | 設計書全体 | 重要指摘を `core/policy.md` に集約し、各サービスへ再配布 |

### 課題・レビュー観点（横断）

- サービスごとの失敗時動作（再試行/打ち切り/通知抑制）を同じ粒度で記述する。
- 実装サンプルがセキュリティ要件（TLS 必須など）を満たすことをレビュー観点に固定する。
- ポート/アダプタ切替時に API 契約やイベント契約を変えないことを運用チェックに含める。


## 横断標準（Cross-cutting Standards） { #横断標準cross-cutting-standards }

[基本的方針（Policy）§8](../core/policy.md#8-大規模類似サービス参照反復版) の「追加設計プラン」を各マイクロサービスに適用するための対応表です。

| 標準                                  | 適用範囲                                                                                          | 実装ガイド                                                                                                                                                                                                           |
| ------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **冪等性（Idempotency Key）**         | 全 Write 系 REST API（POST / PUT / PATCH / DELETE）                                               | `Idempotency-Key` ヘッダを受理し、`user_id+endpoint+key` を Redis に 24h 保持。再送で同一レスポンスを再現。Stripe / Shopify と同等。                                                                                 |
| **Transactional Outbox**              | ドメインイベントを発行するサービス（album / events / storage / timeline / notifications / audit） | 同一 DB トランザクション内で `outbox_events` に INSERT → Publisher がポーリング配信。QueuePort 直接叩きは禁止。                                                                                                      |
| **Saga (Choreography)**               | 多段ワークフロー（アップロード → 変換 → タイムライン → 通知 など）                                | 各サービスが `MediaUploaded` / `MediaTranscoded` / `MemoryPublished` を Outbox 経由で連携。補償イベント `*Failed` を必ず定義。                                                                                       |
| **Circuit Breaker + Backoff**         | 外部呼び出し（FCM / Cognito JWKS / OCI Object Storage / OCI Queue / Postfix / Flipt）             | 失敗率 50%（直近 20 件）で Open、30 秒で Half-Open。Retry: base=200ms, factor=2, jitter=±25%, max=3。                                                                                                                |
| **OpenTelemetry + W3C Trace Context** | 全サービス間通信（HTTP / QueuePort）                                                              | `traceparent` を透過的に伝播し、RED メトリクス（Rate / Errors / Duration）を共通ラベルで出力。                                                                                                                       |
| **SLI/SLO + エラーバジェット**        | 主要 UX パス（upload / timeline / notification / auth）                                           | Grafana / OCI Monitoring で SLO ダッシュボード。枯渇時は Flag で縮退モード。                                                                                                                                         |
| **レート制限**                        | API Gateway + サービス内チェック                                                                  | 認証済み 60 req/min、匿名 10 req/min、アップロード 5 req/min。`429` + `Retry-After`。                                                                                                                                |
| **コンテンツ重複排除（CAS）**         | storage-svc のみ                                                                                  | SHA-256 でデデュプ、参照カウント管理。E2E 暗号化時は Flag で無効化。                                                                                                                                                 |
| **Port / Adapter 命名**               | 全サービス                                                                                        | `StoragePort` / `QueuePort` / `MailPort` / `MediaTranscoderPort` / `CachePort` / `AuthPort` / `FeatureFlagPort`。`S3*` / `SES*` / `SQS*` 等の命名は禁止。                                                            |
| **SMTP 送信の最低要件**               | notifications-svc（MailPort 実装）                                                                | STARTTLS 拡張の広告確認 → TLS 1.2+ で昇格 → AUTH は拡張確認後のみ実行。平文 AUTH 禁止（[クリーンアーキテクチャ: PostfixSMTPAdapter](../clean-architecture/notifications-svc.md#postfixsmtpadapter-mailport-実装)）。 |

## 横断レビュー観点（Peer Review Checklist）

新規 PR / 設計変更のレビュー時に、以下を**必ず確認**する。

1. 禁止キーワードは [`policy.md` §1.3 AWS 利用ポリシー](../core/policy.md#13-aws-利用ポリシー) の禁止一覧を正として確認し、その語が**採用文脈**で登場していないか。
2. Write API に `Idempotency-Key` の受理が記述されているか（または既存の共通ミドルウェアを継承しているか）。
3. ドメインイベント発行が **Outbox 経由** になっているか（QueuePort 直叩きが残っていないか）。
4. 外部呼び出しに Circuit Breaker / Retry 方針が明記されているか。
5. 主要エンドポイントに SLO（p95/p99）が設定されているか。
6. SMTP 送信がある場合、STARTTLS / TLS 1.2+ / AUTH 拡張確認が実装されているか。
7. ログに PII（本文・email・電話番号）が含まれていないか。ID 以外の個人情報は書き出さない。

---

最終更新: 2026-04-19 ポリシー適用（追加設計プラン反映）

