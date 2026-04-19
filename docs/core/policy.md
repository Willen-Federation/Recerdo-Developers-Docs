# 基本的方針 (Policy)

> **対象フェーズ**: Closed Beta 〜 GA 全体
> **最終更新**: 2026-04-19 ポリシー適用
> **位置づけ**: 全ドキュメントの上位方針。個別ドキュメントとの矛盾時は本ドキュメントを優先する。
> **関連コミット**: `80d563d — 基本的方針（ポリシーの適用）`

---

## 1. クラウド / インフラ

### 1.1 Beta フェーズ（Closed Beta 〜 Open Beta）

すべて **OSS / セルフホスト**。AWS は **Cognito のみ** 利用する。

| レイヤ           | プロダクト                                                                               | ホスト先                  |
| ---------------- | ---------------------------------------------------------------------------------------- | ------------------------- |
| 計算（VPS）      | **XServer VPS（6 core / 10 GB RAM）**                                                    | XServer VPS               |
| ストレージ／メール | **CoreServerV2 CORE+X（6 GB）**                                                        | CoreServer                |
| オブジェクトストレージ | **Garage**（S3 互換 OSS、分散対応）                                                 | CoreServerV2 CORE+X       |
| データベース     | **MySQL 8.0**（スキーマは **MariaDB 10.11 互換** を必須条件とする）                        | XServer VPS               |
| キャッシュ       | **Redis**（OSS）                                                                          | XServer VPS               |
| メッセージキュー | **Redis + BullMQ**（Node/TS）／**hibiken/asynq**（Go）                                    | XServer VPS               |
| メール           | **Postfix + Dovecot + Rspamd**（SPF / DKIM / DMARC / IP ウォームアップ必須）              | CoreServerV2 CORE+X       |
| 認証             | **AWS Cognito**（Hosted UI、JWKS 検証）                                                  | AWS                       |
| プッシュ通知     | **Firebase Cloud Messaging (FCM)**                                                        | Google                    |
| Feature Flag    | **Flipt**（OSS）                                                                          | XServer VPS               |
| オブザーバビリティ | Prometheus + Grafana + Loki + Alertmanager                                              | XServer VPS               |
| リバースプロキシ／API Gateway | Traefik（Let's Encrypt 自動化）                                               | XServer VPS               |
| CDN / WAF        | Cloudflare 無料プラン                                                                     | Cloudflare                |

### 1.2 本番フェーズ（GA）

**Oracle Cloud Infrastructure (OCI) ファースト**。AWS は **Cognito のみ** 継続。メールは CoreServerV2 を継続利用する（ポリシー）。

| レイヤ           | プロダクト                                                                               |
| ---------------- | ---------------------------------------------------------------------------------------- |
| 計算             | OCI Compute（VM.Standard.A1.Flex 等、ARM Ampere）                                         |
| オブジェクトストレージ | **OCI Object Storage**（S3 互換 API）                                               |
| データベース     | **OCI MySQL HeatWave** もしくは **MySQL Database Service**（スキーマは MariaDB 10.11 互換を維持） |
| キャッシュ       | **OCI Cache with Redis**                                                                  |
| メッセージキュー | **OCI Queue Service**（AMQP 1.0）                                                         |
| メール           | **CoreServerV2 CORE+X 上の Postfix + Dovecot + Rspamd**（継続。将来的な OCI Email Delivery 移行は Feature Flag で切替可能にする） |
| 認証             | AWS Cognito（継続）                                                                       |
| プッシュ通知     | FCM（継続）                                                                               |
| Feature Flag    | Flipt（OCI VPS 上）                                                                       |
| オブザーバビリティ | OCI Logging / OCI Monitoring 併用、Loki 併走可                                          |

### 1.3 AWS 利用ポリシー

- **利用可能**: Cognito（User Pool・Hosted UI・JWKS）のみ。
- **利用しない**（過去資料に登場する場合は差し替え対象）:
    - AWS **SES / SNS / SQS / DynamoDB / RDS / Aurora / EC2 / EKS / ECS / Fargate / ElastiCache / Lambda / CloudWatch / CloudFront / S3 / Secrets Manager / Shield / WAF / GuardDuty** その他全て
- 他クラウドサービスの利用判断は本ドキュメントへの追記を以て確定とする。

### 1.4 AWS 以外の第三者 SaaS 利用

- **利用**: Firebase FCM、Cloudflare（CDN）、Netlify（ドキュメントサイトホスティング）。
- **未採用**: SendGrid・OneSignal・Auth0・Supabase 等のマネージド代替（理由：AWS Cognito + Postfix + Flipt の自前構成で充足）。

---

## 2. メディア処理

### 2.1 自動変換パイプライン

アップロード時点で以下の変換を **自動実行**（同期/非同期はキュー経由）。

| 入力                                     | 出力                                                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 動画（mp4 / mov / hevc / h.264 他）       | **HLS（360p / 720p / 1080p、6秒セグメント、master.m3u8 + variant playlists）** + サムネイル。原本はアーカイブ保持。 |
| **HEIC / HEIF**                          | **JPEG（q=85）+ WebP（q=80）**（libheif / go-libheif）。原本はアーカイブ保持。                                  |
| **Live Photo**（HEIC + MOV のペア）       | 画像部は HEIC → JPEG/WebP。動画部は HLS。両者を **Apple `com.apple.quicktime.content.identifier`**（asset_identifier）で紐付け、UI 上は 1 カードとして表示。 |
| 通常画像（JPEG / PNG / WebP）             | サムネイル生成（AVIF 検討）、EXIF の回転補正を自動適用。                                                        |

技術スタック:

- 動画トランスコード: **FFmpeg**（`ffmpeg-hls` アダプタ）。CPU 負荷対策のため worker pool + 夜間バッチ化を併用。
- HEIC 変換: **libheif / go-libheif**。
- ポート名: `MediaTranscoderPort`、アダプタ名: `FFmpegHLSAdapter` / `LibheifImageAdapter`。

### 2.2 ハイライトビデオ

- **ユーザー選択方式**に限定する。ML・クラスタリング等による **自動生成は行わない**。
- API（`POST /api/media/{org_id}/highlights`、`POST /albums/{album_id}/highlights` 等）は `media_ids[]` を必須パラメータとし、ユーザーが選んだメディアの **FFmpeg concat** 結果を HLS として書き出す。
- サーバ側の機能は「連結」「トランジションの付与（オプション）」「HLS 化」のみ。

### 2.3 ストレージ削除

- 論理削除（`deleted_at` 設定）＋ **30 日保持** ののち、原本 + 派生ファイルを物理削除。
- 監査系データはより長期の階層保管（§3.2 参照）。

---

## 3. データベース

### 3.1 エンジン

- **Beta**: **MySQL 8.0**（XServer VPS 上で起動、日次ダンプを CoreServerV2 へ転送）。
- **本番**: **OCI MySQL HeatWave**（または MySQL Database Service）。
- **互換性**: **MariaDB 10.11 と同一 SQL が通ること** を必須要件とする。これにより将来的に MariaDB への切替余地を残し、ロックインを回避する。
    - 利用可: `WINDOW 関数` / `CTE` / `JSON 型` / `GENERATED COLUMN` / `CHECK 制約（10.2+）`。
    - 利用不可（MySQL 固有）: `JSON_TABLE`（MariaDB 10.6+ で対応だが互換性確認のため避ける）、`SELECT … FOR UPDATE SKIP LOCKED`（MariaDB 10.6+）など差異の大きな機能。差異は [MariaDB vs MySQL Compatibility](https://mariadb.com/docs/release-notes/community-server/about/compatibility-and-differences/mariadb-vs-mysql-compatibility) を正として判定する。
    - マイグレーションは **Flyway / Liquibase** いずれかで管理し、CI で **MySQL 8.0 + MariaDB 10.11 両方** に流して通ることを確認する。

### 3.2 階層保管ポリシー（監査 / Timeline 等の長期データ）

| 段階 | 保管先                                                        | 典型期間 |
| ---- | ------------------------------------------------------------- | -------- |
| Hot  | MySQL / MariaDB                                                | 〜2年    |
| Warm | Garage（Beta）/ OCI Object Storage（本番）標準ストレージ     | 2〜7年   |
| Cold | Garage / **OCI Object Storage Archive tier**                  | 7年     |
| 削除 | 物理削除（監査対象は別途保管）                                | 7年超   |

S3 へのアーカイブ記述は **すべて禁止**。"S3 互換 API" という表現はアダプタ層の SDK（Garage / OCI 双方をカバーする `aws-sdk-go-v2/service/s3`）を指す場合に限り使用可。

---

## 4. 設計原則

### 4.1 単一コードベース（12-factor）

- 単一リポジトリ。環境差異は **環境変数** と **Feature Flag（Flipt）** で吸収する。
- `if env == "production"` のような環境名分岐は **禁止**。具体的な設定値（`provider == "oci-queue"` 等）で判断する。
- 詳細: [環境抽象化 & Feature Flag](environment-abstraction.md)

### 4.2 ヘキサゴナルアーキテクチャ（Ports & Adapters）

ドメイン層は **Port（インタフェース）** のみを知る。Adapter 実装は DI で差し込む。

**標準ポート名**:

- `StoragePort` / `QueuePort` / `MailPort` / `MediaTranscoderPort` / `CachePort` / `AuthPort` / `FeatureFlagPort` / `ObjectStorageArchivalPort` / `AuditEventPort`

**標準アダプタ名**:

- Storage: `GarageStorageAdapter` / `OCIObjectStorageAdapter`
- Queue: `RedisBullMQAdapter` / `AsynqAdapter` / `OCIQueueAdapter`
- Mail: `PostfixSMTPAdapter`
- Media: `FFmpegHLSAdapter` / `LibheifImageAdapter`
- Auth: `CognitoAuthAdapter`

**禁止アダプタ名**（過去のドキュメントに残存する場合は削除／改名）:

- `S3Adapter` / `S3StorageAdapter` / `MinioAdapter`
- `SQSAdapter` / `SNSAdapter` / `SESAdapter` / `SESEmailAdapter`
- `DynamoDBAdapter` / `RDSAdapter` / `ElastiCacheAdapter`

### 4.3 Feature Flag 駆動

- すべての大きな切替（Beta → 本番、アダプタ入替、段階的ロールアウト、Kill Switch）は Flipt 経由。
- 評価は [Feature Flag Svc](../microservice/feature-flag-system.md) の `EvaluateFlag` に集約し、ローカルキャッシュ TTL 30 秒。

---

## 5. セキュリティ

- **シークレット管理**: Beta = sops + age（`.env.local` を暗号化して Git 管理） / 本番 = OCI Vault。AWS Secrets Manager は不使用。
- **JWT 検証**: Cognito JWKS（`lestrrat-go/jwx` 等）を API Gateway で実施。
- **WAF / DDoS 対策**: Cloudflare（Beta）、OCI WAF（本番）。AWS Shield / WAF は不使用。
- **バックアップ暗号化**: Garage / OCI Object Storage の SSE + アプリ側 age 暗号化（多層）。

---

## 6. 関連ドキュメント

- [デプロイメント戦略](deployment-strategy.md)
- [環境抽象化 & Feature Flag](environment-abstraction.md)
- [コストパフォーマンス分析](cost-performance-analysis.md)
- [サーバーキャパシティ計画](server-capacity-planning.md)
- [ファイアウォール & データプロテクション](firewall-data-protection.md)
- [PoC / Beta スコープ](poc-beta-scope.md)
- [キュー抽象化設計](../microservice/queue-abstraction.md)
- [マイクロサービス一覧](../microservice/index.md)
- [クリーンアーキテクチャ一覧](../clean-architecture/index.md)

---

## 7. 参考

- [Garage — 分散 S3 互換オブジェクトストレージ OSS](https://garagehq.deuxfleurs.fr/documentation/)
- [MariaDB versus MySQL — Compatibility](https://mariadb.com/docs/release-notes/community-server/about/compatibility-and-differences/mariadb-vs-mysql-compatibility)
- [Postfix + Dovecot + Rspamd 運用ガイド](https://www.dchost.com/blog/en/i-built-my-own-mail-server-postfix-dovecot-rspamd-and-the-calm-path-to-deliverability-with-ip-warm%E2%80%91up/)
- [Building an Event-Driven HLS Video Streaming Platform with FFmpeg and Microservices](https://medium.com/@nileshdeshpandework/building-an-event-driven-hls-video-streaming-platform-with-ffmpeg-and-microservices-1839adabbb85)
- [libheif / go-libheif](https://github.com/MaestroError/go-libheif)
- [Apple Live Photo の構造（HEIC + MOV のペア）](https://www.whexy.com/dyn/ec968903-2fab-44ac-8003-62d14cacc2f5)

---

最終更新: 2026-04-19 ポリシー適用
