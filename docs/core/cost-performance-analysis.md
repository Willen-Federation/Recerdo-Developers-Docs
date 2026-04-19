# コストパフォーマンス分析

> **対象フェーズ**: PoC / Beta（ユーザー数 100〜1,000 人規模）〜 本番
> **最終更新**: 2026-04-19
> **ステータス**: 承認待ち

!!! note "ポリシー準拠"
    本ドキュメントは最新インフラポリシーに準拠して全面再構築されています。Beta=**XServer VPS 6 core/10 GB + CoreServerV2 CORE+X**、本番=**OCI ファースト**。AWS 利用は **Cognito のみ**、メールは両フェーズで **CoreServerV2 上の Postfix+Dovecot+Rspamd**、オブジェクトストレージは Beta=**Garage (S3互換 OSS)**／本番=**OCI Object Storage**。

---

## 1. エグゼクティブサマリー

Recerdo の PoC/Beta フェーズでは、**月額 ¥6,000 程度（日本円固定費）** で全インフラを自前運用し、本番フェーズでは OCI へ段階移行する。AWS の利用は Cognito（MAU 無料枠内）に限定し、メール配信は IP ウォームアップを計画的に行った **自前 Postfix+Dovecot+Rspamd** を採用する。

---

## 2. Beta 構成のコスト内訳（月額・税込・2025/2026 参考価格）

### 2.1 固定インフラ費

| 項目                                   | プラン                  | 月額（参考）     | 備考                                                                                   |
| -------------------------------------- | ----------------------- | ---------------- | -------------------------------------------------------------------------------------- |
| **XServer VPS**                        | 6 core / 10 GB RAM      | **約 ¥3,960**    | 12ヶ月契約時の実勢価格。全マイクロサービス + MySQL + Redis + Flipt + Loki を同居       |
| **CoreServerV2 CORE+X**                | 6 GB ストレージ         | **約 ¥1,738**    | Garage（S3互換 OSS）+ Postfix+Dovecot+Rspamd + 静的アセット + MySQL 日次バックアップ   |
| ドメイン + TLS                         | Cloudflare 無料 / Let's Encrypt | 約 ¥100        | ドメイン年 ¥1,200 程度を12ヶ月按分                                                     |
| Cloudflare                             | Free tier               | ¥0               | CDN + WAF + DDoS（5ルール）                                                            |
| **合計（Beta 固定費）**                |                         | **約 ¥5,800/月** |                                                                                        |

### 2.2 AWS（Cognito のみ）

| 項目                 | 月額       | 備考                                |
| -------------------- | ---------- | ----------------------------------- |
| AWS Cognito          | **$0**     | 50,000 MAU 無料枠。Beta 中は余裕あり |
| （AWS 他サービス）    | **¥0**     | SES / SNS / SQS / S3 は不採用        |

### 2.3 Firebase

| 項目                      | 月額   | 備考                              |
| ------------------------- | ------ | --------------------------------- |
| Firebase Cloud Messaging  | **¥0** | プッシュ通知、完全無料・無制限     |

### 2.4 OSS ミドルウェアのライセンス費

全て **¥0**（Docker で自前運用）：
- MySQL（Community Edition、**スキーマは MariaDB 互換に保つ**）
- Redis（OSS）+ BullMQ / asynq
- Garage（S3互換オブジェクトストレージ）
- Postfix + Dovecot + Rspamd
- Flipt（Feature Flag）
- Grafana Loki（ログ集約）
- Traefik（API Gateway / リバースプロキシ）
- ffmpeg（HLS 変換）+ libheif（HEIC 変換）

### 2.5 Beta 合計

| 構成                         | 月額（JPY 換算） |
| ---------------------------- | ---------------- |
| **推奨: 全 OSS セルフホスト** | **約 ¥5,800〜¥6,000** |

---

## 3. 本番構成のコスト内訳（OCI ファースト）

Open Beta 〜 GA フェーズ。MAU 1,000〜50,000 を想定。

| コンポーネント             | 本番サービス                            | 月額見積（参考）    | 備考                                                                                          |
| -------------------------- | --------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| コンピュート               | OCI Compute（VM.Standard.A1.Flex）      | ¥0〜¥5,000           | Always Free 枠（4 OCPU / 24 GB）を活用、超過分のみ課金                                        |
| データベース               | OCI MySQL HeatWave / MySQL Database Service | ¥6,000〜¥15,000     | **スキーマは MariaDB 互換を維持**                                                             |
| キャッシュ                 | OCI Cache with Redis                    | ¥3,000〜¥8,000      |                                                                                               |
| キュー                     | OCI Queue Service（AMQP 1.0）           | ¥1,000〜¥5,000      | リクエスト課金                                                                                |
| オブジェクトストレージ     | OCI Object Storage                      | ¥500〜¥3,000        | Standard tier、エグレス 10TB/月 無料                                                          |
| ロードバランサ / API GW    | OCI Load Balancer + API Gateway         | ¥2,500〜¥5,000      |                                                                                               |
| ログ集約                   | OCI Logging または Loki 継続            | ¥0〜¥3,000          |                                                                                               |
| メール（継続）             | **CoreServerV2 CORE+X の Postfix+Dovecot+Rspamd** | **約 ¥1,738**       | **本番でも継続**。IP warm-up 済み                                                             |
| 認証                       | AWS Cognito                             | $0〜（MAU課金）      | 50,000 MAU までは無料、超過時は $0.0055/MAU                                                   |
| プッシュ通知               | Firebase FCM                            | ¥0                  | 完全無料                                                                                      |
| CDN                        | Cloudflare Free または Pro ($20)         | ¥0〜¥3,000          |                                                                                               |
| **合計（本番）**           |                                         | **約 ¥15,000〜¥45,000/月** | MAU と動画配信量で変動                                                                |

---

## 4. メール配信の評価（自前 Postfix+Dovecot+Rspamd）

### 4.1 方針

Recerdo のメール配信は **全フェーズを通して CoreServerV2 CORE+X 上の Postfix + Dovecot + Rspamd で自前運用** する。AWS SES は **採用しない**。

### 4.2 リスクと緩和策

| リスク              | 影響度 | 緩和策                                                                                                      |
| ------------------- | ------ | ----------------------------------------------------------------------------------------------------------- |
| IP レピュテーション | 高     | 送信量を段階的に増やす **IP warm-up を 30〜60 日**で計画実施。初期は社内テスター + Closed Beta 招待者のみに限定 |
| ブロックリスト登録  | 中     | Rspamd で発信スパム検知を有効化、Bounce 率を監視                                                            |
| SPF/DKIM/DMARC 設定 | 中     | ゾーンファイルに全て設定、DMARC は `p=quarantine` から開始し、運用安定後 `p=reject` へ                      |
| 運用コスト          | 中     | パッチは `unattended-upgrades` + Dovecot/Postfix の月次アップデート                                         |

参考: [I built my own mail server: Postfix, Dovecot, Rspamd — the calm path to deliverability with IP warm-up](https://www.dchost.com/blog/en/i-built-my-own-mail-server-postfix-dovecot-rspamd-and-the-calm-path-to-deliverability-with-ip-warm%E2%80%91up/)

### 4.3 判定

!!! success "自前メール運用を採用"
    Closed Beta 開始の 30 日前から IP warm-up を開始すれば、Beta リリースに間に合う。CoreServerV2 CORE+X の SMTP 機能を活用することで追加コストはゼロ。

---

## 5. 認証サービス比較

| 項目                | AWS Cognito（採用）       | Firebase Auth             | セルフホスト (Keycloak 等) |
| ------------------- | ------------------------- | ------------------------- | -------------------------- |
| MAU 無料枠          | **50,000 MAU**            | 50,000 MAU                | 無制限（サーバー費のみ）   |
| SMS OTP             | $0.015〜/通               | $0.01〜0.05/通            | Twilio 等: $0.0079/通      |
| ソーシャルログイン  | OIDC/SAML                 | Google/Apple/Facebook     | 要設定                     |
| JWT 発行            | Cognito JWT (RS256)       | Firebase ID Token (RS256) | 標準 JWT                   |
| **採用理由**        | 既存設計書の前提、ユーザープール移行コスト回避 | —                         | —                          |

!!! tip "認証は Cognito で決定（AWS 利用はここに限定）"
    既存のクリーンアーキテクチャ設計書で Cognito 前提が確定しており、AWS 利用は **Cognito のみ** のポリシー。これは本番でも変更なし。

---

## 6. メディア変換コストの考慮

Recerdo はアップロードされた動画を **HLS（360p/720p/1080p の ABR、6 秒セグメント）に自動変換**、HEIC 画像を **JPEG/WebP に変換**、Live Photos は **画像 + 短尺 HLS のペア** として保持する。

| 項目                           | Beta（XServer VPS）                                    | 本番（OCI）                                               |
| ------------------------------ | ------------------------------------------------------ | --------------------------------------------------------- |
| 変換方式                       | ffmpeg + libheif（OSS）を Docker ワーカーで実行        | ffmpeg + libheif（同じ Docker イメージ）                  |
| CPU 負荷                       | 高（1080p 変換は 1 クリップで 1〜2 core を瞬間消費）   | 高                                                        |
| コスト                         | VPS に内包（追加課金なし）                             | 秒単位課金、バッチ化して低減                              |
| スケール戦略                   | CPU quota + 第二 VPS オフロード                        | ジョブキュー + 水平スケール                               |

!!! info "ハイライト動画はユーザー選択制"
    ハイライト動画は **ユーザーが手動で選択したクリップを結合して HLS 化する** 方針であり、ML / クラスタリング等の自動生成は **行わない**。サーバー側は単に選択されたクリップを結合し HLS 出力するだけ。参考: [HLS 動画配信パイプラインの構築](https://medium.com/@nileshdeshpandework/building-an-event-driven-hls-video-streaming-platform-with-ffmpeg-and-microservices-1839adabbb85)

---

## 7. スケールアップパス

```
Phase 1 (PoC/Beta)                     Phase 2 (Open Beta / 初期本番)          Phase 3 (GA)
─────────────────────────────          ─────────────────────────────           ──────────────────────────────
XServer VPS 6C/10GB                →   OCI Compute (A1.Flex 増強)          →  OCI Compute + Auto Scaling
CoreServerV2 Garage                →   OCI Object Storage                  →  OCI Object Storage + Archive
MySQL on VPS (MariaDB互換)         →   OCI MySQL HeatWave (MariaDB互換)    →  OCI MySQL + Read Replica
Redis + BullMQ on VPS              →   OCI Cache with Redis                →  OCI Cache Cluster
                                       + OCI Queue Service                     + DLQ / 優先度キュー
CoreServerV2 Postfix+Dovecot+Rspamd →  （継続）                            →  （継続、送信 IP 増強）
Cognito                            →   Cognito                             →  Cognito
FCM                                →   FCM                                 →  FCM
Flipt on VPS                       →   Flipt on OCI                        →  Flipt on OCI
Cloudflare Free                    →   Cloudflare Free〜Pro                →  Cloudflare Pro + OCI Origin
```

| フェーズ           | ユーザー数      | 月額見積                |
| ------------------ | --------------- | ----------------------- |
| Phase 1 (PoC/Beta) | 100〜1,000      | **約 ¥6,000**           |
| Phase 2 (Growth)   | 1,000〜10,000   | ¥15,000〜¥30,000        |
| Phase 3 (Scale)    | 10,000〜50,000  | ¥30,000〜¥80,000        |

---

## 8. 意思決定ログ

| 決定                               | 代替案（不採用）        | 理由                                                                  |
| ---------------------------------- | ----------------------- | --------------------------------------------------------------------- |
| Garage（S3互換 OSS）採用            | MinIO / AWS S3          | ライセンス・地理分散向きの設計・CoreServerV2 上で運用可能              |
| 自前 Postfix+Dovecot+Rspamd 採用    | AWS SES / SendGrid      | コスト一定化、AWS 依存の最小化                                        |
| Cognito 採用                       | Firebase Auth / Keycloak | 既存設計書との整合、MAU 50K 無料                                      |
| FCM 継続                           | AWS SNS Mobile Push     | 完全無料・クロスプラットフォーム SDK                                  |
| XServer VPS 6C/10GB 採用            | Hetzner / DigitalOcean  | 東京リージョン・日本語サポート・実勢価格                              |
| CoreServerV2 CORE+X 採用            | さくらレンタル / ConoHa WING | メール自前運用がしやすい、Garage 起動実績あり                         |
| MySQL 採用（MariaDB 互換維持）      | PostgreSQL / NoSQL      | 既存 GORM 実装互換、OCI MySQL Database Service との整合                |
| 本番キュー = OCI Queue Service     | AWS SQS / RabbitMQ      | AWS 依存を回避、AMQP 1.0 標準                                         |
| HLS 変換は自前 ffmpeg              | AWS MediaConvert        | AWS 依存を回避、OSS で完結                                            |
| ハイライト動画はユーザー選択制     | 自動ハイライト生成（ML）| プライバシー・コスト・実装コストの観点で見送り                        |

---

## 9. 採用／不採用の理由（ポリシー対照表）

| 項目                 | 採用                                                          | 不採用                                                                          | 理由                                                                                                  |
| -------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| オブジェクトストレージ | **Garage (Beta) / OCI Object Storage (本番)**                 | **AWS S3 / CloudFront / MinIO**                                                 | OCI はエグレス約 **13倍安価**、Garage は OSS・地理分散向き。MinIO は採用しない。                       |
| コンピュート         | **XServer VPS (Beta) / OCI Compute A1.Flex (本番)**           | **AWS EC2 / ECS / Fargate / EKS / Lambda**                                      | OCI は AWS EC2 比で **約 57% 安価**、A1.Flex は Always Free 枠あり                                    |
| ブロックストレージ   | **OCI Block Volume**                                          | **AWS EBS**                                                                     | OCI は AWS EBS 比で **約 78% 安価**                                                                   |
| データベース         | **MySQL 8.0 (MariaDB 10.11 互換) / OCI MySQL HeatWave**       | **AWS RDS / Aurora / DynamoDB**                                                 | AWS 依存回避、MariaDB 互換で将来のロックイン回避                                                      |
| キャッシュ           | **Redis (Beta) / OCI Cache with Redis (本番)**                | **AWS ElastiCache**                                                             | AWS 依存回避、OSS で完結                                                                              |
| メッセージキュー     | **Redis+BullMQ / asynq (Beta) / OCI Queue Service (本番)**    | **AWS SQS / SNS**                                                               | AWS 依存回避、AMQP 1.0 標準                                                                           |
| メール               | **Postfix + Dovecot + Rspamd on CoreServerV2**                | **AWS SES / SendGrid**                                                          | コスト一定化、AWS 依存回避、IP warm-up で到達率確保                                                   |
| 認証                 | **AWS Cognito**                                               | Firebase Auth / Keycloak                                                         | **AWS 利用はここのみ**。既存設計書前提、MAU 50,000 無料                                               |
| プッシュ通知         | **Firebase FCM**                                              | **AWS SNS Mobile Push**                                                          | 完全無料・無制限                                                                                      |
| CDN                  | **Cloudflare Free〜Pro / OCI CDN**                            | **AWS CloudFront**                                                              | Cloudflare は無料枠・運用容易、CloudFront は不採用                                                    |
| ログ                 | **Grafana Loki (OSS) / OCI Logging**                          | **AWS CloudWatch Logs**                                                         | AWS 依存回避                                                                                          |
| Feature Flag         | **Flipt (OSS)**                                               | AWS AppConfig / LaunchDarkly (有料)                                              | OSS セルフホスト                                                                                      |
| 監視                 | **Prometheus + Grafana + Alertmanager**                       | **AWS CloudWatch / Datadog (有料)**                                              | AWS 依存回避、OSS で完結                                                                              |

!!! info "S3 互換 API の扱い"
    "S3 互換 API" という表現は、`aws-sdk-go-v2/service/s3` を **Garage / OCI Object Storage どちらにも向ける SDK 記述としてのみ許可**。AWS S3 サービス本体は不採用。

---

最終更新: 2026-04-19 ポリシー適用
