# サーバーキャパシティ計画

> **対象フェーズ**: PoC/Beta → Growth
> **最終更新**: 2026-04-19
> **ステータス**: 承認待ち

!!! note "ポリシー準拠"
    本ドキュメントは最新インフラポリシーに準拠しています。Beta 基盤は **XServer VPS 6 core / 10 GB RAM** + **CoreServerV2 CORE+X (6 GB)**。HLS / HEIC 変換は ffmpeg / libheif を Docker ワーカーで実行するため CPU 負荷を計画に織り込んでいます。DB は MySQL（**MariaDB 互換スキーマを維持**）、オブジェクトストレージは **Garage**（S3互換 OSS）。

---

## 1. 前提条件

### 1.1 ユーザー規模想定

| フェーズ    | 登録ユーザー  | DAU (日次アクティブ) | 同時接続 | 期間     |
| ----------- | ------------- | -------------------- | -------- | -------- |
| PoC         | 50〜100       | 20〜40               | 5〜10    | 1〜2ヶ月 |
| Closed Beta | 100〜500      | 50〜150              | 15〜40   | 2〜3ヶ月 |
| Open Beta   | 500〜2,000    | 200〜600             | 50〜150  | 3〜6ヶ月 |
| Growth      | 2,000〜10,000 | 800〜3,000           | 200〜800 | 6ヶ月〜  |

### 1.2 トラフィックパターン（PoC/Beta）

Recerdo は「旧友との Social Media」であるため、以下のパターンを想定:

| 時間帯             | 割合 | 特性                           |
| ------------------ | ---- | ------------------------------ |
| 朝 (7-9時)         | 15%  | 通知確認・軽い閲覧             |
| 昼 (12-14時)       | 20%  | 投稿閲覧・返信                 |
| 夕方〜夜 (18-23時) | 50%  | メイン利用時間・投稿・チャット |
| 深夜〜早朝         | 15%  | 低トラフィック（HLS 変換バッチを夜間に寄せる余地あり） |

---

## 2. リクエスト量の見積

### 2.1 ユーザーあたりのAPI呼び出し

1セッション（平均15分）あたりの API 呼び出し:

| 操作                          | 呼び出し回数              | サイズ  |
| ----------------------------- | ------------------------- | ------- |
| タイムライン取得              | 3〜5回                    | 10KB/回 |
| プロフィール参照              | 2〜3回                    | 2KB/回  |
| イベント操作                  | 1〜2回                    | 5KB/回  |
| 通知取得                      | 2〜3回                    | 3KB/回  |
| メッセージ送受信              | 5〜10回                   | 1KB/回  |
| 画像アップロード（HEIC含む）  | 0〜1回                    | 3MB/回  |
| 動画アップロード              | 0〜0.2回                  | 30MB/回 |
| HLS マニフェスト・セグメント取得 | 5〜20回（再生時のみ）      | 1〜2MB/回 |
| **合計**                      | **約15〜30回/セッション** |         |

### 2.2 RPS（Requests Per Second）計算

| フェーズ    | DAU   | セッション/日 | API呼出/日 | ピークRPS | 平均RPS |
| ----------- | ----- | ------------- | ---------- | --------- | ------- |
| PoC         | 30    | 60            | 1,200      | 0.5       | 0.01    |
| Closed Beta | 100   | 250           | 5,000      | 2         | 0.06    |
| Open Beta   | 400   | 1,200         | 24,000     | 8         | 0.3     |
| Growth      | 2,000 | 6,000         | 120,000    | 40        | 1.4     |

!!! info "PoC/Beta のトラフィック"
    API リクエスト自体は **最大でも 10 RPS 未満** で、単一 XServer VPS（6 core）で十分処理可能。ボトルネックは **HLS / HEIC 変換の CPU 負荷** 側にある（§3 参照）。

---

## 3. リソースサイジング（XServer VPS 6 core / 10 GB）

### 3.1 Beta: 単一 VPS 構成

```
┌───────────────────────────────────────────────────┐
│     XServer VPS: 6 core / 10 GB RAM               │
│                                                   │
│  ┌──────────┐  CPU: 0.1 core                      │
│  │ Traefik  │  RAM: 80MB                          │
│  └────┬─────┘                                     │
│       │                                           │
│  ┌────▼────────────────────────┐                  │
│  │  Go/Node Services (Docker)  │                  │
│  │  ├─ auth-svc      0.2 core  │                  │
│  │  ├─ core-svc      0.4 core  │                  │
│  │  ├─ event/timeline 0.4 core │                  │
│  │  ├─ album-svc     0.2 core  │                  │
│  │  ├─ messaging-svc 0.3 core  │                  │
│  │  ├─ notif-svc     0.2 core  │                  │
│  │  ├─ audit-svc     0.1 core  │                  │
│  │  ├─ permission    0.1 core  │                  │
│  │  ├─ admin-console 0.1 core  │                  │
│  │  └─ flipt         0.1 core  │                  │
│  │  小計: ~2.1 core / 2.0 GB   │                  │
│  └─────────────────────────────┘                  │
│                                                   │
│  ┌─────────────────────────────┐                  │
│  │ Media Transcoder Workers     │                  │
│  │  ├─ ffmpeg-hls   1.5 core   │ ★ CPU重           │
│  │  └─ libheif       0.3 core  │                  │
│  │  小計: ~1.8 core (burst 3c) │                  │
│  └─────────────────────────────┘                  │
│                                                   │
│  ┌────────────┐  CPU: 0.8 core                    │
│  │  MySQL     │  RAM: 2.5 GB (InnoDB Pool 2GB)    │
│  │  (MariaDB互換スキーマ)                           │
│  └────────────┘                                   │
│                                                   │
│  ┌────────────┐  CPU: 0.3 core                    │
│  │  Redis 7.x │  RAM: 400 MB (+ BullMQ)           │
│  └────────────┘                                   │
│                                                   │
│  ┌────────────┐  CPU: 0.2 core                    │
│  │ Grafana Loki│  RAM: 300 MB                      │
│  └────────────┘                                   │
│                                                   │
│  空き: ~0.8 core / 4.7 GB（バースト/ピーク用）       │
└───────────────────────────────────────────────────┘
```

### 3.2 各コンポーネントのリソース配分

| コンポーネント     | CPU予約       | メモリ予約 | メモリ上限 | 備考                                         |
| ------------------ | ------------- | ---------- | ---------- | -------------------------------------------- |
| Traefik            | 0.1 core      | 80MB       | 128MB      | TLS終端 + API Gateway                        |
| auth-svc           | 0.2 core      | 128MB      | 256MB      | Cognito JWT 検証                             |
| core-svc           | 0.4 core      | 256MB      | 512MB      | ユーザー・組織・イベント・タイムライン       |
| album-svc          | 0.2 core      | 128MB      | 256MB      | Garage 署名URL + メタデータ                  |
| messaging-svc      | 0.3 core      | 256MB      | 512MB      | WebSocket + Redis Pub/Sub                    |
| notification-svc   | 0.2 core      | 128MB      | 256MB      | FCM + Postfix SMTP 送信                      |
| audit / permission / admin-console / flipt | 各 0.1 core | 各 128MB   | 各 256MB   |                                              |
| **ffmpeg HLS worker** | 1.5 core (burst 3) | 512MB  | 1GB        | **CPU 重**。変換中は他サービスに影響する可能性 |
| libheif worker     | 0.3 core      | 256MB      | 512MB      | HEIC→JPEG/WebP 変換                          |
| MySQL 8.0（MariaDB互換） | 0.8 core | 2.5GB      | 3GB        | `innodb_buffer_pool_size=2G`                 |
| Redis 7.x + BullMQ | 0.3 core      | 400MB      | 768MB      | キュー + セッション + キャッシュ             |
| Grafana Loki       | 0.2 core      | 300MB      | 512MB      | ログ集約                                     |
| **合計（定常）**   | **~5.2 core** | **~6.0 GB** | **~9 GB** | 6 core / 10 GB VPS に収まる                  |

### 3.3 HLS 変換の負荷戦略

ffmpeg による HLS ABR（360p/720p/1080p、6 秒セグメント）変換は **CPU 非常に重い** 処理。

| 戦略                       | 内容                                                                                                 |
| -------------------------- | ---------------------------------------------------------------------------------------------------- |
| **CPU Quota 設定**         | `docker-compose` で `cpus: '2'`、優先度は他サービスより低く（`cpu_shares: 256`）                     |
| **ジョブキュー経由**       | アップロードと変換を同期させず、Redis + BullMQ に投入。オンデマンド再生時のフォールバック変換は行わない |
| **オフピーク寄せ**         | 夜間帯（01:00〜06:00 JST）に未変換ジョブをバッチ処理                                                 |
| **プリセット選定**         | `preset=veryfast` + `crf=23` で速度優先。品質は `preset=medium` を本番フェーズで再検討                |
| **第二 VPS へのオフロード** | Growth フェーズで変換専用 XServer VPS を追加し、ネットワーク経由で入出力                             |

参考: [HLS 配信パイプラインの構築（ffmpeg + マイクロサービス）](https://medium.com/@nileshdeshpandework/building-an-event-driven-hls-video-streaming-platform-with-ffmpeg-and-microservices-1839adabbb85)

### 3.4 Docker Compose リソース制限設定例

```yaml
# docker-compose.yml (抜粋)
services:
  core-svc:
    image: recerdo/core-svc:latest
    deploy:
      resources:
        limits:
          cpus: '0.8'
          memory: 512M
        reservations:
          cpus: '0.4'
          memory: 256M
    environment:
      - GOMAXPROCS=1

  media-transcoder:
    image: recerdo/media-transcoder:latest
    deploy:
      resources:
        limits:
          cpus: '3.0'  # バースト時は 3 core まで
          memory: 1G
        reservations:
          cpus: '1.5'
          memory: 512M
    environment:
      - MEDIA_TRANSCODER=ffmpeg-hls
      - MEDIA_HLS_VARIANTS=360p,720p,1080p
      - MEDIA_HLS_SEGMENT_SEC=6

  mysql:
    image: mysql:8.0
    deploy:
      resources:
        limits:
          cpus: '1.2'
          memory: 3G
        reservations:
          cpus: '0.8'
          memory: 2.5G
    command: >
      --innodb-buffer-pool-size=2048M
      --max-connections=100
      --thread-cache-size=16
      --sql-mode=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION
      --default-storage-engine=InnoDB
```

!!! warning "MariaDB 互換性の維持"
    `JSON_TABLE`（MySQL 8.0.4+）、一部の MySQL 専用 CHECK 制約、MySQL 独自の空間関数などは使用しない。ウィンドウ関数は MariaDB 10.6+ でも利用可のため OK。CI で MariaDB 10.6 に対する互換性テストを走らせる。参考: [MariaDB vs MySQL Compatibility](https://mariadb.com/docs/release-notes/community-server/about/compatibility-and-differences/mariadb-vs-mysql-compatibility)

---

## 4. データベースキャパシティ

### 4.1 データ量見積（Closed Beta: 500ユーザー）

| テーブル       | レコード数/月 | レコードサイズ    | 月間データ量   |
| -------------- | ------------- | ----------------- | -------------- |
| users          | 500           | 1KB               | 0.5MB          |
| organizations  | 50            | 2KB               | 0.1MB          |
| org_users      | 1,000         | 0.5KB             | 0.5MB          |
| events         | 200           | 3KB               | 0.6MB          |
| timeline_posts | 3,000         | 2KB               | 6MB            |
| post_media     | 1,500         | 0.5KB（メタのみ） | 0.75MB         |
| messages       | 10,000        | 1KB               | 10MB           |
| album_media    | 2,000         | 0.5KB（メタのみ） | 1MB            |
| media_variants | 3,000         | 0.3KB（HLS/HEIC 変換後メタ） | 0.9MB          |
| notifications  | 5,000         | 0.5KB             | 2.5MB          |
| access_logs    | 50,000        | 0.3KB             | 15MB           |
| **合計**       |               |                   | **約 38MB/月** |

!!! success "データベース容量"
    6ヶ月運用でも **約 230MB** であり、XServer VPS 内の MySQL で十分。InnoDB Buffer Pool 2GB に対して余裕がある。

### 4.2 クエリパフォーマンス指標

| クエリタイプ                      | 目標レイテンシ | インデックス戦略               |
| --------------------------------- | -------------- | ------------------------------ |
| ユーザー検索 (PK)                 | < 1ms          | PRIMARY KEY                    |
| タイムライン取得 (組織別・時系列) | < 10ms         | (org_id, created_at DESC)      |
| イベント一覧 (組織別・日付範囲)   | < 5ms          | (org_id, start_date)           |
| メッセージ取得 (スレッド別)       | < 5ms          | (thread_id, created_at)        |
| 通知一覧 (ユーザー別・未読)       | < 5ms          | (user_id, is_read, created_at) |

---

## 5. ストレージキャパシティ（Garage on CoreServerV2 CORE+X）

### 5.1 オブジェクトストレージ見積

| コンテンツタイプ                            | 月間アップロード数 | 平均サイズ | 月間データ量    |
| ------------------------------------------- | ------------------ | ---------- | --------------- |
| プロフィール画像                            | 100                | 200KB      | 20MB            |
| 投稿画像（オリジナル + HEIC→JPEG/WebP）     | 1,500              | 1.5MB      | 2.25GB          |
| アルバム写真（オリジナル + 変換版）         | 2,000              | 2.5MB      | 5GB             |
| 動画（オリジナル）                          | 200                | 30MB       | 6GB             |
| 動画（HLS マスタ + レンディション + セグメント） | 200                | 50MB（合計） | 10GB            |
| Live Photos ペア（画像 + 短尺 HLS）         | 300                | 4MB        | 1.2GB           |
| サムネイル（自動生成）                      | 4,000              | 50KB       | 200MB           |
| **合計**                                    |                    |            | **約 24.7GB/月** |

!!! warning "CoreServerV2 CORE+X 容量上限"
    CORE+X の 6GB ストレージ枠では月産 24GB のメディアを格納しきれない。Beta では以下のいずれかを選択：
    - **CoreServerV2 の上位プランに切替**（実運用で最初に発生する制約）
    - **メディアは XServer VPS 内 Garage（追加ディスク）へ退避**、CoreServerV2 はバックアップ/メール専用
    - **Open Beta 以降、早期に OCI Object Storage へ移行**

### 5.2 ストレージコスト（参考）

| 項目                         | 6ヶ月累計 | コスト（JPY 概算）          |
| ---------------------------- | --------- | --------------------------- |
| Garage on CoreServerV2        | 最大 6GB  | ¥1,738/月 × 6 = ¥10,428     |
| （超過時）OCI Object Storage | 約 150GB  | 約 ¥1,500/6ヶ月             |
| エグレス（CDN 経由）         | 動画再生量次第 | Cloudflare 無料枠内で吸収可 |

---

## 6. WebSocket キャパシティ

### 6.1 接続数見積

| フェーズ    | 同時WebSocket接続 | メモリ使用量 | 備考                                |
| ----------- | ----------------- | ------------ | ----------------------------------- |
| PoC         | 5〜10             | 5〜10MB      | 1接続 ≈ 1MB (Go goroutine + buffer) |
| Closed Beta | 15〜40            | 15〜40MB     |                                     |
| Open Beta   | 50〜150           | 50〜150MB    |                                     |
| Growth      | 200〜800          | 200〜800MB   | Redis Pub/Sub による分散要検討      |

### 6.2 メッセージスループット

| フェーズ | メッセージ/秒 | 帯域      | 処理方法                     |
| -------- | ------------- | --------- | ---------------------------- |
| PoC/Beta | 1〜5 msg/s    | < 50KB/s  | 単一Go プロセス              |
| Growth   | 10〜50 msg/s  | < 500KB/s | Redis Pub/Sub + 複数ワーカー |

---

## 7. Beta インフラ選定（確定）

!!! tip "Beta フェーズ確定構成"
    - **VPS**: **XServer VPS 6 core / 10 GB RAM**（約 ¥3,960/月）  
    - **レンタルサーバー**: **CoreServerV2 CORE+X（6 GB）**（約 ¥1,738/月）  
    - **CDN**: Cloudflare Free  
    - **合計月額**: 約 ¥6,000  
    
    他 VPS（Hetzner / DigitalOcean / Vultr / Linode）は検討対象外。日本リージョンかつ国内サポート・メール運用のしやすさから XServer + CoreServerV2 に確定済み。

---

## 8. 監視・アラート

### 8.1 Beta で最低限必要な監視

| 監視項目                      | ツール                        | アラート閾値     |
| ----------------------------- | ----------------------------- | ---------------- |
| CPU使用率                     | Prometheus + Grafana (Docker) | > 80% 持続5分    |
| メモリ使用率                  | Prometheus + node_exporter    | > 85%            |
| ディスク使用率                | node_exporter                 | > 80%            |
| HTTP エラー率                 | Traefik access log            | 5xx > 5%         |
| API レスポンスタイム          | Go middleware (Prometheus)    | p95 > 500ms      |
| MySQL 接続数                  | mysqld_exporter               | > 80 / 100       |
| HLS 変換ジョブ遅延            | BullMQ メトリクス              | 待機 > 5分       |
| メール送信失敗率（Postfix）   | Postfix ログ + Prometheus     | bounce > 5%      |
| Docker コンテナ状態           | cAdvisor                      | restart > 3/h    |

### 8.2 Beta では不要な監視

| 項目                      | 理由                                       |
| ------------------------- | ------------------------------------------ |
| APM (Datadog/New Relic)   | 有料。Prometheus + Grafana + Loki で十分   |
| 分散トレーシング (Jaeger) | サービス間通信が HTTP 直接のため不要       |
| 外部ログ SaaS             | Loki（OSS）で完結                          |

---

## 9. スケールアップ判断基準

以下の閾値に達したら、次のフェーズのインフラへ移行する:

| 指標                     | 閾値           | アクション                                                 |
| ------------------------ | -------------- | ---------------------------------------------------------- |
| CPU使用率                | 持続的に > 70% | 第二 XServer VPS 追加（メディア変換オフロード）            |
| メモリ使用率             | 持続的に > 80% | VPS スペックアップ or OCI 移行                             |
| 同時WebSocket接続        | > 100          | Redis Pub/Sub 本格活用 + メッセージング専用ノード分離       |
| DBレコード数             | > 100万行      | OCI MySQL Database Service 移行検討                         |
| 日次API呼出              | > 100K         | ロードバランサー導入 + 複数ノード                          |
| Garage 使用量            | > 5GB（CORE+X 上限近傍） | OCI Object Storage へ移行 or 追加ディスク           |
| HLS 変換ジョブ待機       | 常時 > 5分     | 変換専用 VPS を追加                                        |
| オブジェクトストレージ   | > 100GB        | Cloudflare CDN または OCI CDN 導入（AWS CloudFront は不採用） |
| DAU                      | > 1,000        | 本番 OCI（Compute A1.Flex + MySQL HeatWave + Object Storage）へ段階移行開始（AWS ECS Fargate / RDS は不採用） |

---

最終更新: 2026-04-19 ポリシー適用
