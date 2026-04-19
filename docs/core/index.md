# コアプラットフォーム

Recerdo のインフラストラクチャ、運用計画、セキュリティに関する横断的なアーキテクチャドキュメントです。

!!! note "インフラポリシー（2026-04-19 更新）"
    - **Beta**: 全 OSS / セルフホスト。**XServer VPS 6 core / 10 GB** + **CoreServerV2 CORE+X (6 GB)**。オブジェクトストレージは **Garage (S3互換 OSS)**、メールは **Postfix + Dovecot + Rspamd**、キューは **Redis + BullMQ / asynq**、Feature Flag は **Flipt**、ログは **Grafana Loki**。
    - **本番**: **Oracle Cloud Infrastructure (OCI) ファースト**。OCI Object Storage、OCI MySQL HeatWave（**MariaDB 互換スキーマを維持**）、OCI Queue Service（AMQP 1.0）、OCI Cache with Redis。メールは **CoreServerV2 の Postfix+Dovecot+Rspamd を継続**。
    - **AWS 利用は Cognito のみ**（SES/SNS/SQS/S3/RDS/ElastiCache/CloudFront/EC2/EKS/Lambda は全て不採用）。Firebase FCM は継続。
    - メディア処理は ffmpeg（HLS ABR: 360p/720p/1080p、6 秒セグメント）+ libheif（HEIC→JPEG/WebP）。Live Photos は画像 + 短尺 HLS のペア保存。**ハイライト動画はユーザーが手動でクリップを選択**（自動生成なし）。

## ドキュメント一覧

| ドキュメント | 概要 |
|---|---|
| [デプロイメント戦略](deployment-strategy.md) | Beta（XServer VPS + CoreServerV2 CORE+X）→ 本番（OCI ファースト）への移行戦略。AWS は Cognito のみ |
| [環境抽象化 & Feature Flag](environment-abstraction.md) | ハードコード排除・環境変数/Feature Flag/アダプタの3層切替。`STORAGE_PROVIDER=garage\|oci-oss`、`QUEUE_PROVIDER=redis-bullmq\|oci-queue`、`MAIL_PROVIDER=postfix-smtp`、`MEDIA_TRANSCODER=ffmpeg-hls` |
| [コストパフォーマンス分析](cost-performance-analysis.md) | XServer VPS (~¥3,960/月) + CoreServerV2 CORE+X (~¥1,738/月) + Cognito (無料枠)。Beta 合計 約 ¥6,000/月 |
| [PoC/Beta スコープ定義](poc-beta-scope.md) | バイブコーディングで実現する MVP 機能セット。HLS/HEIC/Live Photos 変換 + 手動選択ハイライトを含む |
| [サーバーキャパシティ計画](server-capacity-planning.md) | XServer VPS 6 core/10 GB 上のリソース配分。ffmpeg HLS 変換の CPU 負荷と第二 VPS オフロード戦略 |
| [ファイアウォール & データプロテクション](firewall-data-protection.md) | Cloudflare + ufw + Traefik + Cognito + MySQL(MariaDB互換)暗号化。バックアップは Garage / OCI Object Storage |

## 設計反復（追加プラン）ガイド

- 基本方針の追加設計プランは [基本的方針 (Policy)](policy.md) の「8. 追加設計プラン（大規模類似サービス参照）」を正典とする。
- 各サービス文書の課題・レビュー記録は、マイクロサービス設計とクリーンアーキテクチャ設計の両インデックスへ再反映する。
- 重要指摘（セキュリティ・可用性・可観測性）は「個別修正 → 横断方針更新」の順で必ず反復する。
