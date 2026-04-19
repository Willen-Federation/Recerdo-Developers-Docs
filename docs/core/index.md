# コアプラットフォーム

Recerdo のインフラストラクチャ、運用計画、セキュリティに関する横断的なアーキテクチャドキュメントです。

!!! note "インフラポリシー（2026-04-19 更新）"
    - **Beta**: 全 OSS / セルフホスト。**XServer VPS 6 core / 10 GB** + **CoreServerV2 CORE+X (6 GB)**。オブジェクトストレージは **Garage (S3互換 OSS)**、メールは **Postfix + Dovecot + Rspamd**、キューは **Redis + BullMQ / asynq**、Feature Flag は **Flipt**、ログは **Grafana Loki**。
    - **本番**: **Oracle Cloud Infrastructure (OCI) ファースト**。OCI Object Storage、OCI MySQL HeatWave（**MariaDB 互換スキーマを維持**）、OCI Queue Service（AMQP 1.0）、OCI Cache with Redis。メールは **CoreServerV2 の Postfix+Dovecot+Rspamd を継続**。
    - **AWS 利用は Cognito のみ**（SES/SNS/SQS/S3/RDS/ElastiCache/CloudFront/EC2/EKS/Lambda は全て不採用）。Firebase FCM は継続。
    - メディア処理は ffmpeg（HLS ABR: 360p/720p/1080p、6 秒セグメント）+ libheif（HEIC→JPEG/WebP）。Live Photos は画像 + 短尺 HLS のペア保存。**ハイライト動画はユーザーが手動でクリップを選択**（自動生成なし）。

!!! tip "追加設計プラン（大規模類似サービス参照）"
    [基本的方針（Policy）§8](policy.md#8-大規模類似サービス参照反復版) にて、Google Photos / Instagram / Stripe / Netflix / Google SRE 等の一般モデルを参照した**横断標準**を整理しました。

    - **冪等性（Idempotency Key）**: 全 Write API に `Idempotency-Key` を受理（24h 保持）。
    - **Transactional Outbox**: DB 書込と QueuePort 送信のアトミック性を保証。
    - **Saga (Choreography)**: アップロード → 変換 → タイムライン → 通知 をイベント連携。
    - **Circuit Breaker + 指数バックオフ**: FCM / Cognito / OCI 呼び出しに適用。
    - **OpenTelemetry + W3C Trace Context**: RED メトリクスと `traceparent` 伝播。
    - **SLI/SLO + エラーバジェット**: 主要 UX パスに P95/P99 目標を設定。

    横断表は [microservice/index.md](../microservice/index.md#横断標準cross-cutting-standards) / [clean-architecture/index.md](../clean-architecture/index.md#横断パターン) で同期管理。

## ドキュメント一覧

| ドキュメント                                                           | 概要                                                                                                                                                                                                 |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [デプロイメント戦略](deployment-strategy.md)                           | Beta（XServer VPS + CoreServerV2 CORE+X）→ 本番（OCI ファースト）への移行戦略。AWS は Cognito のみ                                                                                                   |
| [環境抽象化 & Feature Flag](environment-abstraction.md)                | ハードコード排除・環境変数/Feature Flag/アダプタの3層切替。`STORAGE_PROVIDER=garage\|oci-oss`、`QUEUE_PROVIDER=redis-bullmq\|oci-queue`、`MAIL_PROVIDER=postfix-smtp`、`MEDIA_TRANSCODER=ffmpeg-hls` |
| [コストパフォーマンス分析](cost-performance-analysis.md)               | XServer VPS (~¥3,960/月) + CoreServerV2 CORE+X (~¥1,738/月) + Cognito (無料枠)。Beta 合計 約 ¥6,000/月                                                                                               |
| [PoC/Beta スコープ定義](poc-beta-scope.md)                             | バイブコーディングで実現する MVP 機能セット。HLS/HEIC/Live Photos 変換 + 手動選択ハイライトを含む                                                                                                    |
| [サーバーキャパシティ計画](server-capacity-planning.md)                | XServer VPS 6 core/10 GB 上のリソース配分。ffmpeg HLS 変換の CPU 負荷と第二 VPS オフロード戦略                                                                                                       |
| [ファイアウォール & データプロテクション](firewall-data-protection.md) | Cloudflare + ufw + Traefik + Cognito + MySQL(MariaDB互換)暗号化。バックアップは Garage / OCI Object Storage                                                                                          |

## 横断ドキュメント更新フロー

1. サービス設計書（MS / CA）で**失敗条件**と**運用上の制約**を明文化する。
2. 該当する横断標準（[policy.md §8](policy.md#8-大規模類似サービス参照反復版)）の適用有無を確認する。
3. 不足している場合は policy.md §8 に追記し、[microservice/index.md](../microservice/index.md) と [clean-architecture/index.md](../clean-architecture/index.md) の横断表に同期反映する。
4. CI（禁止キーワード grep / STARTTLS 検査等）で逸脱を検出する運用を維持する。
5. [changelog.md](../changelog.md) に反復の記録を残す。
