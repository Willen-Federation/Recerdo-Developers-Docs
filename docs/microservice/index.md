# マイクロサービス設計

Recerdoのバックエンドは、責務ごとに分離されたマイクロサービスで構成されています。各サービスは独立してデプロイ可能で、**キュー抽象化レイヤー**（[キュー抽象化設計](queue-abstraction.md)）を介した非同期メッセージングで連携します。実装は Beta では **Redis + BullMQ / asynq**、本番では **OCI Queue Service** に差し替わります（コード変更なし、Feature Flag + 環境変数で切替）。

## サービス一覧

| サービス名                                    | リポジトリ名               | 主な責務                               | ステータス |
| --------------------------------------------- | -------------------------- | -------------------------------------- | ---------- |
| [Authentication Service](auth-svc.md)         | recuerdo-auth-svc          | 認証・JWT・セッション管理              | Draft      |
| [Audit Service](audit-svc.md)                 | recuerdo-audit-svc         | 監査ログ・コンプライアンス             | Draft      |
| [Album Service](album-svc.md)                 | recuerdo-album-svc         | アルバム・写真・メモリ管理             | Draft      |
| [Events Service](events-svc.md)               | recuerdo-events-svc        | イベント・通知・リアクション           | Draft      |
| [Timeline Service](timeline-svc.md)           | recuerdo-timeline-svc      | タイムライン・フィード生成             | Draft      |
| [Storage Service](storage-svc.md)             | recuerdo-storage-svc       | オブジェクトストレージ・メディア管理・HLS変換・HEIC変換 | Draft      |
| [Notification Service](notifications-svc.md)  | recuerdo-notifications-svc | Push / Email 配信                      | Draft      |
| [Feature Flag System](feature-flag-system.md) | recuerdo-feature-flag-svc  | Feature Flag・段階的ロールアウト       | Approved   |
| [Admin Console Service](admin-console-svc.md) | recuerdo-admin-console-svc | 運用・モデレーション・管理者コンソール | Draft      |

## 横断基盤ドキュメント

| ドキュメント                             | 概要                                                                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------- |
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

| 項目           | Beta（セルフホスト）                   | 本番（OCIファースト）                    |
| -------------- | -------------------------------------- | ---------------------------------------- |
| 言語           | Go 1.22+ / Ruby 3.3+（Admin Rails 版） | 同左                                     |
| フレームワーク | Echo / Gin / Rails 8                   | 同左                                     |
| データベース   | MySQL 8.0 / MariaDB 10.11（XServer VPS、MariaDB 互換性をテスト） | OCI MySQL HeatWave        |
| キャッシュ     | Redis 7.x（XServer VPS 共用）          | OCI Cache with Redis                     |
| メッセージング | **Redis + BullMQ** (Node) または **asynq** (Go) | **OCI Queue Service**            |
| ストレージ     | Garage（S3互換 OSS, CoreServerV2 CORE+X） | OCI Object Storage                    |
| メール         | Postfix + Dovecot + Rspamd（CoreServerV2） | 同左（CoreServerV2 継続利用）        |
| Push           | FCM (Firebase Cloud Messaging)         | 同左                                     |
| 認証           | AWS Cognito + JWT (RS256)              | 同左                                     |
| Feature Flag   | Flipt + OpenFeature                    | 同左                                     |
| メディア変換   | FFmpeg (HLS) / libheif (HEIC)          | 同左（OCI Container Instances 実行）     |
| 監視ログ       | Prometheus + Loki + Grafana            | 同左                                     |
| コンテナ       | Docker Compose / k3s                   | OCI Container Instances                  |
| IaC            | Terraform                              | 同左（プロバイダのみ切替）               |

すべての差分は **Feature Flag + 環境変数** で切替可能（[環境抽象化](../core/environment-abstraction.md) 参照）。AWS サービスは **Cognito のみ** 利用し、SQS / SES / S3 / DynamoDB / RDS / MinIO / EC2 / EKS / ElastiCache / Lambda / CloudFront は採用しない（[基本的方針（ポリシー）](../core/policy.md) 参照）。

---

最終更新: 2026-04-19 ポリシー適用

