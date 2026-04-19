# PoC/Beta スコープ定義 — バイブコーディング戦略

> **対象フェーズ**: PoC → Closed Beta
> **開発アプローチ**: バイブコーディング（AI支援ラピッドプロトタイピング）
> **最終更新**: 2026-04-19
> **ステータス**: 承認待ち

!!! note "ポリシー準拠"
    本ドキュメントは最新インフラポリシーに準拠しています。Beta 基盤は **XServer VPS + CoreServerV2 CORE+X**（全 OSS）、認証は **AWS Cognito のみ**、オブジェクトストレージは **Garage (S3互換 OSS)**、メールは **Postfix+Dovecot+Rspamd**。ハイライト動画は **ユーザーが手動で選択したクリップを結合** する方針で、自動生成（ML / クラスタリング）は行いません。

---

## 1. バイブコーディングとは

バイブコーディングは、AIコーディングアシスタント（Claude Code, Cursor, GitHub Copilot 等）を最大限活用し、**自然言語による指示 → コード生成 → テスト → デプロイ** を高速に回す開発手法である。

### 1.1 Recerdo における適用方針

| 原則 | 説明 |
|---|---|
| **既存コード活用** | Recuerdo_Backend の Go/Gin/GORM 実装をベースに拡張 |
| **AI 生成コード率 70%+** | 定型的な CRUD・ミドルウェア・テストは AI に委譲 |
| **手動レビュー必須** | セキュリティ関連（認証・認可・暗号化）は人間がレビュー |
| **完璧より動作優先** | エッジケースは Beta ユーザーフィードバックで修正 |
| **設計ドキュメント駆動** | 既存の DD/CA 設計書を AI への入力コンテキストとして活用 |

### 1.2 バイブコーディングに適する/適さない領域

| 適する（AI委譲） | 適さない（手動実装） |
|---|---|
| REST API エンドポイント | JWT 検証ミドルウェア |
| GORM モデル定義・マイグレーション（MariaDB 互換チェック付き） | 暗号化・ハッシュ処理 |
| バリデーションロジック | Postfix/Dovecot/Rspamd 設定（メール送信の品質に直結） |
| 単体テスト生成 | Garage / OCI Object Storage アダプタ境界 |
| Docker Compose 設定 | 本番セキュリティ設定 |
| API ドキュメント生成 | インフラ権限設計 |

---

## 2. PoC/Beta フィーチャーマトリクス

### 2.1 優先度定義

| ラベル | 意味 | Beta リリース |
|---|---|---|
| **P0 — Must Have** | Beta で必須。これがないとアプリとして成立しない | 必須 |
| **P1 — Should Have** | Beta 体験を大幅に向上。リソースがあれば実装 | 推奨 |
| **P2 — Nice to Have** | プロダクション向け。Beta では省略可 | 不要 |

### 2.2 機能一覧

#### 認証 (Auth) — P0

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| メール/パスワード登録・ログイン | P0 | 高（Cognito Hosted UI） | 1日 |
| Google ソーシャルログイン | P0 | 高（Cognito IdP 連携） | 0.5日 |
| Apple ソーシャルログイン | P1 | 高（Cognito IdP 連携） | 0.5日 |
| JWT トークン検証 (Go middleware) | P0 | 中（セキュリティレビュー必要） | 1日 |
| パスワードリセット | P0 | 高（Cognito 組み込み） | 0.5日 |
| SMS OTP 認証 | P2 | — | Phase 2 |
| MFA (多要素認証) | P2 | — | Phase 3 |

#### コアサービス — P0

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| ユーザープロフィール CRUD | P0 | 高 | 1日 |
| 組織 (Organization) 作成・参加 | P0 | 高 | 2日 |
| 組織メンバー管理 | P0 | 高 | 1日 |
| 招待リンク生成・承認 | P0 | 高 | 1日 |
| ユーザー検索 | P1 | 高 | 0.5日 |

#### イベント (Events) — P0

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| イベント作成・編集・削除 | P0 | 高 | 1.5日 |
| イベント参加・辞退 | P0 | 高 | 1日 |
| イベント一覧・詳細表示 | P0 | 高 | 0.5日 |
| リマインダー通知 | P1 | 高（FCM 連携） | 1日 |
| 繰り返しイベント | P2 | — | Phase 2 |

#### タイムライン (Timeline) — P0

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| 投稿作成（テキスト + 画像） | P0 | 高 | 1.5日 |
| タイムライン表示（ページネーション） | P0 | 高 | 1日 |
| 投稿へのリアクション | P1 | 高 | 0.5日 |
| コメント機能 | P1 | 高 | 1日 |
| メディア添付（複数画像） | P1 | 中 | 1.5日 |

#### アルバム (Album) & メディア変換 — P1

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| アルバム作成・共有 | P1 | 高 | 1.5日 |
| 画像アップロード（**Garage 署名付きURL** 経由） | P1 | 中 | 1.5日 |
| **HEIC → JPEG/WebP 自動変換（libheif / go-libheif）** | P1 | 中 | 1日 |
| **動画 → HLS 自動変換（ffmpeg、360p/720p/1080p、6秒セグメント）** | P1 | 中 | 2日 |
| **Live Photos ペア保存（画像 + 短尺 HLS、`asset_identifier` で紐付け）** | P1 | 中 | 1日 |
| アルバム閲覧・ダウンロード | P1 | 高 | 1日 |
| **ハイライト動画：ユーザーが手動でクリップを選択 → 結合 → HLS 配信** | P1 | 中 | 2日 |
| コメント・タグ付け | P2 | — | Phase 2 |

!!! warning "ハイライト動画は完全ユーザー選択制"
    ML ベースの自動クラスタリング・スマートハイライト生成は **実装しません**。ユーザーが手動で選択したクリップをサーバー側で順に連結（ffmpeg concat）し、HLS として配信します。

#### メッセージング — P1

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| 1対1 テキストメッセージ | P1 | 中（WebSocket） | 3日 |
| グループメッセージ | P1 | 中 | 2日 |
| 既読表示 | P2 | — | Phase 2 |
| 画像・ファイル送信 | P2 | — | Phase 2 |

#### 通知 (Notification) — P1

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| プッシュ通知（FCM） | P1 | 高（Firebase SDK） | 1.5日 |
| メール通知（**Postfix SMTP 経由 / CoreServerV2**） | P1 | 高（標準 net/smtp） | 1日 |
| 通知設定 ON/OFF | P1 | 高 | 0.5日 |
| 通知テンプレート管理 | P2 | — | Phase 2 |

#### ソーシャルグラフ — P2

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| フレンドリクエスト | P2 | — | Phase 2 |
| フレンド提案 | P2 | — | Phase 2 |
| 連絡先インポート | P2 | — | Phase 3 |
| ブロック機能 | P2 | — | Phase 2 |

#### 監査・セキュリティ — P2

| 機能 | 優先度 | バイブコーディング適性 | 実装見積 |
|---|---|---|---|
| 基本アクセスログ | P1 | 高（ミドルウェア） | 0.5日 |
| GDPR データ削除 | P2 | — | Phase 2 |
| 監査ログ詳細 | P2 | — | Phase 2 |

---

## 3. PoC/Beta 実装ロードマップ

### Phase 0: 基盤構築（1週間）

```
Week 1
├── XServer VPS セットアップ（Docker Compose、Beta は単一ノード運用）
├── CoreServerV2 CORE+X に Garage（S3互換 OSS）セットアップ
├── CoreServerV2 に Postfix + Dovecot + Rspamd セットアップ（SPF/DKIM/DMARC）
├── AWS Cognito User Pool 作成 + Hosted UI 設定
├── Go JWT 検証ミドルウェア（Cognito JWKS 対応）
├── Docker Compose 環境整備（Go + MySQL [MariaDB互換] + Redis + BullMQ + Traefik + Loki + Flipt）
├── ffmpeg / libheif ワーカーコンテナ作成
├── CI/CD パイプライン（GitHub Actions → XServer VPS デプロイ）
└── 開発環境ドキュメント整備
```

**バイブコーディングのポイント**: Docker Compose、CI/CD、Traefik 設定は AI に全文生成させて微調整のみ。Postfix/Rspamd は手動で検証。IP warm-up を Week 1 から開始。

### Phase 1: コア機能（2〜3週間）

```
Week 2-3
├── Auth: Cognito 統合 + JWT ミドルウェア
├── Core: ユーザー・組織 CRUD API
├── Events: イベント CRUD + 参加管理
├── Timeline: 投稿 CRUD + ページネーション
└── Storage: Garage 署名付きURL 生成（S3 互換 SDK）
```

```
Week 4
├── 統合テスト（MariaDB 10.6 互換性チェック含む）
├── フロントエンド接続確認
└── ステージング環境デプロイ
```

**バイブコーディングのポイント**: 各サービスの CRUD は設計書 (DD/CA) を AI に渡して一括生成。テストも AI 生成 → 人間が境界値を追加。DB スキーマは **MariaDB 10.6 互換性を CI でチェック**。

### Phase 2: 拡張機能（2〜3週間）

```
Week 5-6
├── Notification: FCM プッシュ通知 + Postfix SMTP メール
├── Album: アルバム CRUD + 画像アップロード（Garage）
├── Media Transcoder: HEIC→JPEG/WebP + 動画→HLS（360p/720p/1080p）
├── Live Photos ペア保存 (`com.apple.quicktime.content.identifier` の抽出)
├── ハイライト動画: ユーザー選択 → ffmpeg concat → HLS 出力
├── Messaging: WebSocket 基盤 + 1対1チャット
└── アクセスログミドルウェア
```

```
Week 7
├── E2E テスト
├── パフォーマンステスト（k6）
├── HLS 変換負荷テスト（ffmpeg ワーカーの CPU 影響測定）
├── Beta ユーザー向けオンボーディング
└── 本番環境デプロイ
```

### 合計見積

| 項目 | 工数 |
|---|---|
| P0 機能 | 約 12人日 |
| P1 機能（HLS/HEIC/Live Photos/ハイライト選択含む） | 約 20人日 |
| テスト・デプロイ | 約 6人日 |
| **合計** | **約 38人日（8週間 @ 1人）** |

!!! tip "バイブコーディングによる短縮効果"
    従来手法での見積: 約 70人日。バイブコーディングにより **約 45% の工数削減** を見込む。特に CRUD API・テスト・設定ファイルでの効果が大きい。

---

## 4. 技術スタック（PoC/Beta 確定版）

```
Frontend:
  - Flutter (iOS + Android + Web)
  - AWS Cognito Hosted UI / SDK
  - Firebase Cloud Messaging SDK
  - HLS.js / native HLS プレイヤー

Backend:
  - Go 1.24 + Gin + GORM
  - MySQL 8.0（スキーマは MariaDB 10.6 互換）
  - Redis 7.x + BullMQ / asynq
  - Traefik (Reverse Proxy + API Gateway + TLS)
  - Flipt (Feature Flag OSS)
  - Grafana Loki (ログ集約)

Media Processing:
  - ffmpeg（HLS ABR、360p/720p/1080p、6秒セグメント）
  - libheif / go-libheif（HEIC → JPEG/WebP）
  - Live Photos ペア識別子: com.apple.quicktime.content.identifier

Infrastructure (Beta):
  - XServer VPS (6 core / 10 GB RAM)  — 計算層
  - CoreServerV2 CORE+X (6 GB)         — Garage + メール + 静的 + バックアップ
  - Docker Compose（Beta は単一ノード運用。本番は OCI Container Instances または OKE）
  - GitHub Actions (CI/CD)
  - Let's Encrypt (TLS)
  - Cloudflare Free (CDN + WAF + DDoS)

Object Storage:
  - Garage (S3互換 OSS) on CoreServerV2 CORE+X

Mail (Beta & Prod 共通):
  - Postfix + Dovecot + Rspamd on CoreServerV2 CORE+X
  - SPF / DKIM / DMARC 設定済み
  - IP warm-up 30〜60日計画

External Services:
  - AWS Cognito (認証 — AWS 利用はここのみ)
  - Firebase Cloud Messaging (プッシュ通知)
```

---

## 5. Beta リリース基準

Beta リリースのゲート条件:

| 基準 | 条件 | 検証方法 |
|---|---|---|
| 機能完成度 | P0 機能 100% + P1 機能 50%以上 | Flipt でのフラグ確認 |
| テストカバレッジ | ユニットテスト 60%以上 | `go test -cover` |
| パフォーマンス | API レスポンス p95 < 500ms | k6 負荷テスト |
| セキュリティ | 認証フロー動作確認 + HTTPS強制 | 手動テスト |
| DB 互換性 | MariaDB 10.6 でも CI が PASS | GitHub Actions matrix |
| メール到達率 | Gmail / Yahoo Japan への到達率 > 95% | Postmaster Tools + Rspamd ログ |
| HLS 品質 | 主要3端末で再生、ABR 切替動作 | 手動テスト |
| 可用性 | 24時間連続稼働テスト | サーバー監視 |
| ドキュメント | API ドキュメント + セットアップガイド | レビュー |

---

## 6. Beta 後のプロダクション移行チェックリスト

Beta 終了後、プロダクションに移行する際に追加で必要な項目:

| 項目 | 理由 | 見積 |
|---|---|---|
| XServer VPS → OCI Compute 移行 | オートスケール・可用性 | 3日 |
| MySQL on VPS → OCI MySQL HeatWave 移行（**MariaDB 互換スキーマ維持**） | マネージド運用・HA | 2日 |
| Redis on VPS → OCI Cache with Redis | マネージド運用 | 1日 |
| Redis+BullMQ → **OCI Queue Service（AMQP 1.0）** | マネージド運用 | 2日 |
| Garage on CoreServerV2 → **OCI Object Storage** | スケール・DR | 3日 |
| Postfix+Dovecot+Rspamd on CoreServerV2 | **継続利用**（変更なし） | 0日 |
| Cognito | **継続**（変更なし） | 0日 |
| Cloudflare Pro へアップグレード（任意） | 高度な WAF | 0.5日 |
| GDPR 完全対応 | データ削除カスケード | 5日 |
| 監査ログ強化 | コンプライアンス | 3日 |
| 負荷テスト（本格） | 10K 同時接続 | 2日 |

!!! info "移行ロードマップのポリシー"
    VPS → **OCI Compute A1.Flex（または OKE）** への移行を採用。**AWS ECS Fargate / EC2 / Lambda は不採用**（ポリシー準拠）。

---

最終更新: 2026-04-19 ポリシー適用
