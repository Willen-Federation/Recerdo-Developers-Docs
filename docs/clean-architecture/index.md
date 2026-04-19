# クリーンアーキテクチャ設計

Recerdoの各サービスはクリーンアーキテクチャ（Clean Architecture）に基づいて設計されています。  
Uncle Bobが提唱するレイヤー分離の原則に従い、ビジネスロジックを外部依存から完全に分離します。

## アーキテクチャ原則

```mermaid
graph TB
    subgraph FD["🔵 Frameworks & Drivers（外側）"]
        HTTP["HTTP / REST"]
        DB["MySQL (MariaDB互換) / Redis"]
        MQ["Redis+BullMQ / OCI Queue"]
        subgraph IA["🟣 Interface Adapters"]
            CTRL["Controllers"]
            GW["Gateways"]
            PRES["Presenters"]
            subgraph AB["🟢 Application Business"]
                UC["Use Cases"]
                subgraph EB["🟡 Enterprise Business（内側）"]
                    ENT["Entities<br/>(Domain Models)"]
                    RULE["Business Rules"]
                end
            end
        end
    end

    style FD fill:#0d47a1,color:#fff,stroke:#0d47a1
    style IA fill:#4a148c,color:#fff,stroke:#4a148c
    style AB fill:#1b5e20,color:#fff,stroke:#1b5e20
    style EB fill:#e65100,color:#fff,stroke:#e65100
```

## 依存性の方向

**外側 → 内側** への一方向のみ。内側のレイヤーは外側のレイヤーを知らない。

```mermaid
flowchart LR
    FD["Frameworks & Drivers<br/><small>DB / HTTP / MQ</small>"]
    IA["Interface Adapters<br/><small>Controllers / Repos</small>"]
    AB["Application Business<br/><small>Use Cases</small>"]
    EB["Enterprise Business<br/><small>Entities / Rules</small>"]

    FD -->|"依存"| IA
    IA -->|"依存"| AB
    AB -->|"依存"| EB

    style FD fill:#1565c0,color:#fff,stroke:#1565c0
    style IA fill:#6a1b9a,color:#fff,stroke:#6a1b9a
    style AB fill:#2e7d32,color:#fff,stroke:#2e7d32
    style EB fill:#e65100,color:#fff,stroke:#e65100
```

- `Entities` — ドメインモデル、ビジネスルール（外部依存ゼロ）
- `Use Cases` — アプリケーション固有のビジネスロジック
- `Interface Adapters` — Controllers / Repositories（インターフェース実装）
- `Frameworks & Drivers` — DB / HTTP / Message Queue（具体実装）

## 設計書一覧

| サービス                                      | 設計書                     | セクション数 |
| --------------------------------------------- | -------------------------- | ------------ |
| [API Gateway](api-gateway.md)                 | recerdo-api-gateway       | 14           |
| [Authentication Service](auth-svc.md)         | recerdo-auth          | 14           |
| [Audit Service](audit-svc.md)                 | recerdo-audit         | 14           |
| [Album Service](album-svc.md)                 | recerdo-album         | 14           |
| [Events Service](events-svc.md)               | recerdo-events        | 14           |
| [Timeline Service](timeline-svc.md)           | recerdo-timeline      | 14           |
| [Storage Service](storage-svc.md)             | recerdo-storage       | 14           |
| [Notification Service](notifications-svc.md)  | recerdo-notifications | 14           |
| [Feature Flag System](feature-flag-system.md) | recerdo-feature-flag  | 14           |
| [Admin Console Service](admin-console-svc.md) | recerdo-admin-console | 10           |

## 設計書の構成（14セクション）

各設計書は以下の共通構成に従っています：

1. 概要・目的・アーキテクチャ原則
2. レイヤーアーキテクチャ（図）
3. エンティティ層（ドメインモデル）
4. ユースケース層
5. インターフェースアダプター層
6. フレームワーク・ドライバー層
7. 依存性注入（DI）設計
8. データベース設計
9. API設計
10. エラーハンドリング
11. テスト戦略
12. 非機能要件
13. デプロイ・インフラ
14. 変更履歴・レビュー記録

## インフラ方針サマリ（Beta / Prod）

Recerdo は環境ごとに**ポート & アダプタ**を差し替えるヘキサゴナル設計に従う。
AWS の利用は **Cognito のみ**（SES/SQS/SNS/S3/DynamoDB/RDS/EC2/EKS/ElastiCache/Lambda/CloudFront 等は利用しない）。

| レイヤ          | Port                  | Beta アダプタ (XServer VPS / CoreServerV2)      | Prod アダプタ (OCI-first)             |
| --------------- | --------------------- | ----------------------------------------------- | ------------------------------------- |
| Object Storage  | `StoragePort`         | `GarageStorageAdapter`（Garage OSS, S3互換API） | `OCIObjectStorageAdapter`             |
| RDBMS           | `Repository`          | MySQL 8.x / MariaDB 互換                        | OCI MySQL HeatWave（MariaDB 互換SQL） |
| Queue / Job     | `QueuePort`           | `RedisBullMQAdapter` / `AsynqAdapter`           | `OCIQueueAdapter`                     |
| Cache           | `CachePort`           | Redis (self-hosted)                             | OCI Cache with Redis                  |
| Mail (SMTP)     | `MailPort`            | `PostfixSMTPAdapter`（Postfix+Dovecot+Rspamd）  | `PostfixSMTPAdapter`（CoreServerV2）  |
| Media Transcode | `MediaTranscoderPort` | `FFmpegHLSAdapter` / `LibheifImageAdapter`      | 同左（OCI Compute 上で稼働）          |
| Push            | `PushPort`            | `FCMPushAdapter`                                | `FCMPushAdapter`                      |
| Auth (JWT)      | `AuthPort`            | `CognitoAuthAdapter`                            | `CognitoAuthAdapter`                  |
| Feature Flag    | `FlagPort`            | Flipt (self-hosted) + OpenFeature SDK           | Flipt + OpenFeature SDK               |

メディアは全環境共通で、**動画は自動 HLS（360p / 720p / 1080p、6 秒セグメント）**、
**HEIC は libheif で JPEG/WebP に変換**、**Live Photo は `asset_identifier` でペアリング**。
ハイライトビデオは**ユーザー指定の素材のみ**を結合し、**自動生成や ML による推薦は行わない**。

## 追加設計プラン反映（設計・分析・考察の反復）

[基本的方針（Policy）§8](../core/policy.md#8-大規模類似サービス参照反復版) の Iteration-02（コミット `464267` コメント起点）をクリーンアーキテクチャ層に再配布する。

| 設計観点 | 参照モデル | クリーンアーキテクチャでの反映 | レビュー/課題入力（464267 コメント） |
| --- | --- | --- | --- |
| 通知チャネル戦略 | Push-first（LINE / WhatsApp） | Notification UseCase を Push-first 既定にし、`MailPort` 実装を STARTTLS 非対応時はエラー返却に統一。メール送信は 5 条件に限定する。 | STARTTLS 必須を明示し、旧システム記述を除去 |
| Outbox + DLQ | Shopify / Stripe の冪等 + Outbox | `EventPublisherPort` は Outbox 経由が必須。Port 契約に DLQ 監査フックを含め、再試行回数・可視性タイムアウトを共通化。 | 横断一貫性不足を指摘された箇所を CA レイヤに再配置 |
| Fan-out 縮退 | Instagram / Twitter Fan-out ハイブリッド | Timeline UseCase を Fan-out on Write 既定、フォロワー > 500 で Read-time 切替。縮退は Feature Flag 経由で制御。 | スパイク時縮退経路が明文化されていない点を是正 |
| SLO / Error Budget | Google SRE | UseCase 責務に P95/P99 を記述し、Adapter 層で RED メトリクスを emit。エラーバジェット枯渇時の Kill Switch を `FeatureFlagPort` で切替。 | SLO 記述漏れを防ぐレビュー観点を追加 |

### 課題・他者レビューを踏まえた更新方針

- コード例は「動く例」より「安全要件と Port 契約を満たす例」を優先する。
- レビュー指摘は `policy.md` → 本 index → 個別 CA 設計書の順に逆流反映し、SSOT を崩さない。
- UseCase/Port/Adapter の責務と運用要件（監査・再試行・縮退パス）を同じ節内でセット記述する。

## 横断パターン { #横断パターン }

[基本的方針（Policy）§8](../core/policy.md#8-大規模類似サービス参照反復版) で定義した横断標準は、クリーンアーキテクチャ上で以下の層に落とし込む。

| パターン                        | 該当レイヤ                                                      | 実装上の責務                                                                                                                                                              |
| ------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Idempotency Key**             | Interface Adapters（Controller）+ Framework（Redis キャッシュ） | Controller が `Idempotency-Key` ヘッダを読み、`IdempotencyStore` Port（Redis 実装）に問合せてヒット時はキャッシュ応答を返す。UseCase は冪等性を意識しない。               |
| **Transactional Outbox**        | UseCase + Framework（DB）                                       | UseCase が `EventPublisherPort.Publish(event)` を呼び、Adapter 実装が **同一トランザクション内で `outbox_events` に INSERT**。別プロセスのポーラが QueuePort に転送する。 |
| **Saga (Choreography)**         | UseCase（各サービス）                                           | 受信 QueueEvent → UseCase → Outbox に次イベントを書く／補償イベントを書く。中央オーケストレータは置かない。                                                               |
| **Circuit Breaker**             | Interface Adapters（外部サービス Adapter）                      | Adapter が `gobreaker.CircuitBreaker` をラップし、Open 時は `ErrCircuitOpen` を返す。UseCase は Port 越しに通常のエラーとして扱う。                                       |
| **OpenTelemetry**               | Framework + Interface Adapters                                  | `context.Context` にスパンを流し、Port 境界でスパンを作成。ドメイン／UseCase 層は OTel SDK に直接依存しない。                                                             |
| **SLI/SLO 計測**                | Framework（middleware）                                         | HTTP ミドルウェア / QueuePort Consumer ラッパでメトリクスを Prometheus Exporter に emit。                                                                                 |
| **レート制限**                  | Interface Adapters（Gateway / Middleware）                      | Controller 前段のミドルウェアで Token Bucket（Redis Lua）を評価。`RateLimitPort` として抽象化する。                                                                       |
| **Content-Addressable Storage** | UseCase + Infra（storage-svc のみ）                             | UseCase が SHA-256 を算出し、`MediaBlobRepository.FindBySHA256` → ヒット時は参照カウントのみ増加、未ヒット時のみ `StoragePort.PutObject`。                                |
| **SMTP 最低要件**               | Infra Adapter（`PostfixSMTPAdapter`）                           | STARTTLS 広告確認 → TLS 1.2+ 昇格 → AUTH 拡張確認後にのみ `PlainAuth` 実行。未広告時は **エラーを返して失敗**する（平文 AUTH / 平文配送を禁止）。                         |

### 反映のための設計原則

1. **横断標準は Port のインタフェース定義として残す**。UseCase / Entity は実装詳細を知らない。
2. **Adapter 層で横断標準の実装を提供**。Beta / Prod の差異は Adapter 切替で吸収する。
3. **Framework 層のラッパでメトリクス・トレース・リトライを注入**。UseCase のコードを汚さない。
4. **失敗時の責務は UseCase が明示**。`*Failed` ドメインイベントと補償処理は UseCase に記述する。

---

### 14. 変更履歴・レビュー記録（追加設計プラン反映）

各設計書は §14 に以下を追記する運用にする。

- **反映したレビュー指摘**（PR #、コミットハッシュ、指摘概要）
- **採用した横断標準**（本 index の表のどれを適用したか）
- **残課題・今後のレビュー観点**

レビュー反復の履歴は [基本的方針（Policy）§8.11](../core/policy.md#8-大規模類似サービス参照反復版) とも整合させる。

---

最終更新: 2026-04-19 ポリシー適用（追加設計プラン反映・Iteration-02 再整理）
