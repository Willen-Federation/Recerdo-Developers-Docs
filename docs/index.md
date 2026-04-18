# Recerdo Developer Docs

**Recerdo** は旧友・仲良かったグループとの思い出を共有するソーシャルメディアアプリ（Viejo）です。  
このサイトでは、APIリファレンス・マイクロサービス設計・クリーンアーキテクチャ設計を一元管理します。

---

<div class="grid cards" markdown>

-   :material-api: **API ドキュメント**

    ---

    各サービスが公開するREST APIのエンドポイント・リクエスト/レスポンス仕様一覧。

    [:octicons-arrow-right-24: APIドキュメントを見る](api/index.md)

-   :material-server-network: **マイクロサービス設計**

    ---

    ドメインモデル・ユースケース・インフラ設計などのDD（Design Document）。

    [:octicons-arrow-right-24: マイクロサービス設計を見る](microservice/index.md)

-   :material-layers-triple: **クリーンアーキテクチャ設計**

    ---

    レイヤーアーキテクチャ・依存性設計・テスト戦略の詳細設計書。

    [:octicons-arrow-right-24: CA設計を見る](clean-architecture/index.md)

-   :material-feature-search-outline: **機能仕様**

    ---

    機能レベルの詳細設計書。ユースケース・シーケンス図・API設計を含む。

    [:octicons-arrow-right-24: 機能仕様を見る](features/index.md)

</div>

---

## アーキテクチャ概要

```mermaid
graph TB
    Client["🖥️ iOS / Web Client"]
    GW["API Gateway<br/><small>ルーティング・認可・レート制限</small>"]
    Auth["auth-svc"]
    Album["album-svc"]
    Events["events-svc"]
    Storage["storage-svc"]
    Timeline["timeline-svc"]
    Audit["audit-svc<br/><small>横断的監査ログ</small>"]
    SQS["AWS SQS"]

    Client -->|"JWT (RS256)"| GW
    GW --> Auth
    GW --> Album
    GW --> Events
    GW --> Storage
    GW --> Timeline

    Auth -->|"イベント発行"| SQS
    Album -->|"イベント発行"| SQS
    Events -->|"イベント発行"| SQS
    Storage -->|"イベント発行"| SQS
    Timeline -->|"イベント発行"| SQS
    SQS --> Audit

    classDef client fill:#1565c0,stroke:#1565c0,color:#fff,rx:8
    classDef gateway fill:#6a1b9a,stroke:#6a1b9a,color:#fff
    classDef service fill:#1976d2,stroke:#1976d2,color:#fff
    classDef infra fill:#37474f,stroke:#37474f,color:#fff

    class Client client
    class GW gateway
    class Auth,Album,Events,Storage,Timeline service
    class Audit,SQS infra
```

## サービス一覧

| サービス | リポジトリ | 役割 |
|---------|---------|------|
| API Gateway | recuerdo-api-gateway | ルーティング・認可 |
| Auth Service | recuerdo-auth-svc | 認証・JWT・セッション |
| Events Service | recuerdo-events-svc | イベント・招待 |
| Album Service | recuerdo-album-svc | アルバム・写真 |
| Storage Service | recuerdo-storage-svc | メディアファイル |
| Timeline Service | recuerdo-timeline-svc | フィード・タイムライン |
| Audit Service | recuerdo-audit-svc | 監査ログ（横断的） |

---

> **ステータス**: Draft — 2026年4月現在、設計フェーズ
