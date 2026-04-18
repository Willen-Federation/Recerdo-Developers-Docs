# マイクロサービス設計

Recerdoのバックエンドは、責務ごとに分離された6つのマイクロサービスで構成されています。各サービスは独立してデプロイ可能で、SQS/SNSを介した非同期メッセージングで連携します。

## サービス一覧

| サービス名 | リポジトリ名 | 主な責務 | ステータス |
|-----------|------------|---------|---------|
| [Authentication Service](auth-svc.md) | recuerdo-auth-svc | 認証・JWT・セッション管理 | Draft |
| [Audit Service](audit-svc.md) | recuerdo-audit-svc | 監査ログ・コンプライアンス | Draft |
| [Album Service](album-svc.md) | recuerdo-album-svc | アルバム・写真・メモリ管理 | Draft |
| [Events Service](events-svc.md) | recuerdo-events-svc | イベント・通知・リアクション | Draft |
| [Timeline Service](timeline-svc.md) | recuerdo-timeline-svc | タイムライン・フィード生成 | Draft |
| [Storage Service](storage-svc.md) | recuerdo-storage-svc | S3ファイル・メディア管理 | Draft |

## サービス間通信

```
API Gateway
    ├── auth-svc       ← 認証・トークン検証
    ├── album-svc      ← アルバム操作
    ├── events-svc     ← イベント管理
    ├── timeline-svc   ← フィード取得
    └── storage-svc    ← メディアアップロード

各サービス → audit-svc  (SQS経由で監査ログ送信)
auth-svc   → events-svc (SQS: トークン無効化通知)
```

## テクノロジースタック

- **言語**: Go 1.22+
- **フレームワーク**: Echo / Gin
- **データベース**: PostgreSQL (RDS)
- **キャッシュ**: Redis (ElastiCache)
- **メッセージング**: Amazon SQS / SNS
- **ストレージ**: Amazon S3
- **認証**: AWS Cognito + JWT (RS256)
- **コンテナ**: Docker / ECS Fargate
- **IaC**: Terraform
