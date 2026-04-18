# コストパフォーマンス分析

> **対象フェーズ**: PoC / Beta（ユーザー数 100〜1,000 人規模）  
> **最終更新**: 2026-04-15  
> **ステータス**: 承認待ち

---

## 1. エグゼクティブサマリー

Recerdo の PoC/Beta フェーズでは、**月額 $20〜$50 以内** でプッシュ通知・メール配信・認証・ホスティングを実現することを目標とする。本ドキュメントでは Firebase / AWS / セルフホストの 3 パターンを比較し、**Firebase 中心 + AWS 補完** のハイブリッド構成を推奨する。

---

## 2. 比較対象サービス

### 2.1 通知・メール配信

| 項目 | Firebase (FCM) | AWS (SNS + SES) | セルフホスト (Postfix) |
|---|---|---|---|
| プッシュ通知単価 | **無料（無制限）** | $0.50 / 100万件 | N/A（FCM/APNs直接） |
| メール配信単価 | N/A（メール非対応） | $0.10 / 1,000通（EC2発: 月62,000通無料） | サーバー費 $5〜20/月 + 運用工数 |
| 無料枠 | FCM完全無料 | SNS: 100万件/月無料、SES: EC2から62,000通/月無料 | ソフトウェア無料 |
| セットアップ難易度 | 低（SDK統合のみ） | 中（IAM + SDK設定） | 高（DNS/SPF/DKIM/DMARC + IP暖機） |
| 到達率管理 | Google管理 | バウンス/苦情ダッシュボード | 手動監視 + ブロックリスト対応 |
| PoC/Beta月額見積 | **$0** | **$0〜$1** | **$20〜$50 + 運用10h/月** |

### 2.2 認証

| 項目 | Firebase Auth | AWS Cognito | セルフホスト (Keycloak等) |
|---|---|---|---|
| MAU無料枠 | 50,000 MAU | 50,000 MAU（Essentials） | 無制限（サーバー費のみ） |
| SMS OTP | $0.01〜0.05/通 | $0.015〜/通 | Twilio等外部: $0.0079/通 |
| ソーシャルログイン | Google/Apple/Facebook対応 | OIDC/SAML対応 | 要設定 |
| JWT発行 | Firebase独自トークン | Cognito JWT (RS256) | 標準JWT |
| PoC/Beta月額見積 | **$0** | **$0** | **$10〜30（VPS費）** |

!!! tip "PoC/Beta での推奨"
    Firebase Auth（50,000 MAU無料）を使い、SMS OTPは初期は省略してメール + ソーシャルログインのみで開始する。

### 2.3 ホスティング・コンピュート

| 項目 | Firebase Hosting | AWS ECS Fargate | セルフホスト (VPS) |
|---|---|---|---|
| 静的ホスティング | 10GB転送/月無料 | CloudFront + S3: $0.085/GB | $5/月VPS |
| コンテナ実行 | Cloud Run（GCP連携） | $0.04048/vCPU-h + $0.004445/GB-h | $5〜20/月VPS |
| 最小構成月額 | **$0**（静的のみ） | **$15〜30**（0.25vCPU × 3サービス） | **$5〜20** |
| オートスケール | Cloud Run自動 | Fargate自動 | 手動 |
| Go バックエンド対応 | Cloud Run経由 | ECS Fargate直接 | Docker直接 |

### 2.4 データベース

| 項目 | Firestore | AWS RDS (PostgreSQL) | セルフホスト (MySQL/PostgreSQL) |
|---|---|---|---|
| 無料枠 | 1GB保存 + 50K読取/日 | db.t3.micro 12ヶ月無料 | VPS費のみ |
| PoC/Beta月額 | **$0〜$5** | **$0（無料枠）→ $15/月** | **$5〜10（VPS内）** |
| 運用負荷 | なし（フルマネージド） | 低（自動バックアップ） | 高（バックアップ・パッチ管理） |
| 既存Go実装互換性 | 低（NoSQL、GORM非対応） | **高（PostgreSQL、GORM対応）** | 高 |

!!! warning "Firestore の制約"
    現在の Recuerdo_Backend は GORM + MySQL で実装されており、Firestore (NoSQL) への移行はスキーマ再設計が必要。PoC/Beta では **既存の MySQL/PostgreSQL を継続** することを強く推奨する。

---

## 3. 推奨構成: Firebase + AWS ハイブリッド

### 3.1 アーキテクチャ概要

```
┌─────────────────────────────────────────────────┐
│                   クライアント                      │
│          (iOS / Android / Web)                   │
└──────────┬───────────────┬──────────────────────┘
           │               │
    ┌──────▼──────┐  ┌─────▼──────┐
    │ Firebase    │  │ Firebase   │
    │ Auth        │  │ FCM        │
    │ (認証)      │  │ (Push通知)  │
    └──────┬──────┘  └────────────┘
           │ JWT
    ┌──────▼──────────────────────┐
    │     VPS / EC2              │
    │  ┌────────────────────┐    │
    │  │   nginx (Reverse   │    │
    │  │   Proxy + TLS)     │    │
    │  └────────┬───────────┘    │
    │  ┌────────▼───────────┐    │
    │  │  Go Microservices  │    │
    │  │  (Docker Compose)  │    │
    │  └────────┬───────────┘    │
    │  ┌────────▼───────────┐    │
    │  │  MySQL 8.0         │    │
    │  │  (既存実装維持)       │    │
    │  └────────────────────┘    │
    │  ┌────────────────────┐    │
    │  │  Redis             │    │
    │  │  (セッション/キャッシュ) │    │
    │  └────────────────────┘    │
    └────────────────────────────┘
           │
    ┌──────▼──────┐
    │ AWS SES     │
    │ (メール配信)  │
    └─────────────┘
```

### 3.2 サービス選定理由

| 機能 | 選定 | 理由 |
|---|---|---|
| プッシュ通知 | **Firebase FCM** | 完全無料・SDK成熟・APNs/FCMを統一API |
| 認証 | **Firebase Auth** | 50K MAU無料・ソーシャルログイン即時対応・クライアントSDK充実 |
| メール配信 | **AWS SES** | 月62,000通無料（EC2発）・到達率管理付き・SPF/DKIM自動 |
| バックエンド | **VPS (Docker Compose)** | 既存Go実装をそのまま動作・Fargate比で70%コスト削減 |
| データベース | **MySQL 8.0 (VPS内)** | 既存GORM実装互換・移行コストゼロ |
| キャッシュ | **Redis (VPS内)** | WebSocket接続管理・セッションストア |
| ストレージ | **AWS S3** | 5GB無料枠・署名付きURL対応 |

### 3.3 月額コスト見積（PoC/Beta: 500ユーザー想定）

| サービス | 月額 | 備考 |
|---|---|---|
| Firebase Auth | $0 | 500 MAU（50K無料枠内） |
| Firebase FCM | $0 | 完全無料 |
| AWS SES | $0 | 月5,000通想定（62K無料枠内） |
| AWS S3 | $0.12 | 5GB保存 + 転送 |
| VPS (4vCPU/8GB) | $20〜40 | Hetzner/DigitalOcean/Vultr |
| ドメイン + SSL | $1 | Let's Encrypt無料 + ドメイン年$12 |
| **合計** | **$21〜$42/月** | |

!!! success "コスト比較"
    - **Firebase + VPS ハイブリッド**: **$21〜42/月**
    - AWS フルマネージド (Fargate + RDS + Cognito): $80〜150/月
    - セルフホスト全構成: $20〜40/月 + 運用工数 20h/月

---

## 4. セルフホスト メール配信の評価

### 4.1 Postfix セルフホストのリスク

| リスク | 影響度 | 説明 |
|---|---|---|
| IP レピュテーション | 高 | 新規IPは Gmail/Yahoo のレート制限対象。暖機に30〜60日 |
| ブロックリスト登録 | 高 | Spamhaus/Barracuda 登録時、解除交渉に数週間 |
| SPF/DKIM/DMARC設定 | 中 | 誤設定で配信率が急落 |
| 運用コスト | 高 | 監視・ログ分析・バウンス処理で月10〜20時間 |
| セキュリティパッチ | 中 | OpenSSL/Postfix の脆弱性対応が必須 |

### 4.2 判定

!!! danger "PoC/Beta では セルフホストメール を非推奨"
    IP暖機に30〜60日かかり、Beta ローンチに間に合わない。AWS SES の無料枠（62,000通/月）で十分にカバーできるため、メールは SES を使用する。

---

## 5. スケールアップパス

PoC/Beta からプロダクションへの移行計画:

```
Phase 1 (PoC/Beta)          Phase 2 (1K-10K users)       Phase 3 (10K+ users)
─────────────────           ────────────────────          ──────────────────
VPS + Docker Compose   →    ECS Fargate               →  ECS + Auto Scaling
MySQL on VPS           →    RDS MySQL/PostgreSQL      →  Aurora Serverless
Firebase Auth          →    Firebase Auth (継続)       →  Cognito移行検討
FCM (そのまま)          →    FCM (そのまま)             →  FCM (そのまま)
AWS SES                →    SES (継続)                →  SES + SNS統合
Redis on VPS           →    ElastiCache               →  ElastiCache Cluster
S3                     →    S3 + CloudFront           →  CloudFront + WAF
```

| フェーズ | ユーザー数 | 月額見積 |
|---|---|---|
| Phase 1 (PoC/Beta) | 100〜1,000 | $21〜42 |
| Phase 2 (Growth) | 1,000〜10,000 | $100〜300 |
| Phase 3 (Scale) | 10,000〜100,000 | $500〜2,000 |

---

## 6. Firebase Auth → 既存 Cognito 設計との整合

現在の設計ドキュメントは AWS Cognito + JWT (RS256) を前提としている。PoC/Beta で Firebase Auth を採用する場合の差分:

| 項目 | Cognito設計 | Firebase Auth (PoC) | 移行影響 |
|---|---|---|---|
| トークン形式 | Cognito JWT (RS256) | Firebase ID Token (RS256) | JWKSエンドポイント変更のみ |
| 検証方法 | JWKS from Cognito | JWKS from Google | ミドルウェアの URL 設定変更 |
| ユーザープール | Cognito User Pool | Firebase Project | UID体系が異なる |
| API Gateway連携 | Cognito Authorizer | カスタム JWT 検証 | Go ミドルウェアで吸収可能 |

!!! note "移行戦略"
    Go バックエンドの JWT 検証ミドルウェアを **JWKS URL を環境変数化** する設計にしておけば、Firebase → Cognito 移行時はURL変更のみで対応可能。UID のマッピングテーブルを用意する。

---

## 7. 意思決定ログ

| 決定 | 代替案 | 理由 |
|---|---|---|
| FCM採用 | SNS Mobile Push | FCM完全無料 + クロスプラットフォームSDK |
| Firebase Auth採用 | Cognito | クライアントSDKの開発速度・ソーシャルログイン即対応 |
| SES採用 | Postfix / SendGrid | 無料枠十分 + 到達率管理 + IP暖機不要 |
| VPS採用 | ECS Fargate | 月$20 vs $80+。PoC規模では過剰 |
| MySQL継続 | PostgreSQL移行 | 既存GORM実装の互換維持・移行コストゼロ |
