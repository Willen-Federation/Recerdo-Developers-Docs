# Recerdo Platform AI Coding Context (CLAUDE.md)

> **版**: v2.0 (2026-04-22) — オーケストレーター決定 (2026-04-20) 反映済み  
> **適用**: Claude Code / GitHub Copilot 等の AI コーディングアシスタント全般

---

## 1. 役割とミッション

あなたは Recerdo プラットフォームのシニア・フルスタックエンジニアです。本ドキュメントは、AIコーディングアシスタントが各リポジトリを理解し、一貫したアーキテクチャとセキュリティ基準を満たすコードを生成するための共通ルール（エージェントコンテキスト）を定義します。

**全ての生成コードはこのドキュメントのルールに従うこと。例外は認めない。**

---

## 2. アーキテクチャ原則

### 2.1 クリーンアーキテクチャ (Port / Adapter パターン)

全てのバックエンドサービスは Clean Architecture に従うこと:

```
domain/       ← ビジネスロジック・エンティティ (依存なし)
application/  ← ユースケース (domain のみ依存)
adapter/      ← 外部システム実装 (application の Port を実装)
infra/        ← サーバー起動・DI (全層を組み合わせる)
```

### 2.2 命名規則

**Port 名**（抽象化された役割）:
- ✅ `StoragePort`, `QueuePort`, `MailPort`, `CachePort`, `AuthPort`
- ✅ `FeatureFlagPort`, `AuditEventPort`, `MediaTranscoderPort`
- ❌ `S3Port`, `SQSPort`, `SESPort`, `MinIOPort`, `DynamoDBPort` — **禁止**

**Adapter 名**:
- Storage: `GarageStorageAdapter` / `OCIObjectStorageAdapter`
- Queue: `RedisBullMQAdapter` / `AsynqAdapter` / `OCIQueueAdapter`
- Mail: `PostfixSMTPAdapter`
- Auth: `CognitoAuthAdapter`

**ファイル命名**: Go は `snake_case.go`, TypeScript は `camelCase.ts`

### 2.3 技術スタック (確定版 2026-04-22)

| 領域 | スタック | 備考 |
|---|---|---|
| バックエンド | Go 1.24 + Gin + GORM | |
| DB (Beta) | MySQL 8.0 | **MariaDB 10.11 互換必須** ← 10.6 から更新 |
| DB (Prod) | OCI MySQL HeatWave | MariaDB 10.11 互換維持 |
| スキーマ変更 | **gh-ost** (Zero-downtime) | Flyway/Liquibase は軽微変更のみ |
| キャッシュ | Redis 7.x | |
| キュー (Beta) | Redis + asynq (Go) / BullMQ (Node) | |
| キュー (Prod) | OCI Queue Service (AMQP 1.0) | Feature Flag で切替 |
| 認証 | AWS Cognito + JWKS (RS256) | |
| Feature Flag | Flipt + OpenFeature | |
| SPA Frontend | **Next.js 15 + shadcn/ui** (Phase1) | |
| Admin Console | **Next.js 15 + shadcn/ui** (Phase1) | **Rails は Phase3** |
| iOS | Swift 5 + SwiftUI | |
| Android | **Kotlin + Jetpack Compose** | ← Flutter から変更 |
| Desktop | Electron + TypeScript | |

---

## 3. 禁止事項

### 3.1 禁止キーワード (コード・設定・環境変数)

```
# AWS は Cognito 以外全て禁止
S3Adapter / S3Port / S3StorageAdapter
SQSAdapter / SQSPort
SESAdapter / SESEmailAdapter
DynamoDBAdapter / DynamoDBPort
RDSAdapter / ElastiCacheAdapter
MinioAdapter / MinIOPort

# 環境変数での禁止値
STORAGE_PROVIDER=aws-s3
QUEUE_PROVIDER=aws-sqs
MAIL_PROVIDER=aws-ses
```

### 3.2 コーディング禁止パターン

- `if env == "production"` / `if os.Getenv("APP_ENV") == "production"` — 環境名分岐は禁止
  → Feature Flag (`flipt.EvaluateFlag`) で切替ること
- SQL 文字列結合 (`"WHERE id = " + id`) — Prepared Statement / GORM を使うこと
- PII をログに出力すること (`email`, `phone_number`, `password`, `full_name`)
- 空のテスト関数 (`func TestXxx(t *testing.T) {}`) — TDD 必須
- `t.Skip()` / `it.skip()` の無条件使用 — 理由なきスキップ禁止

### 3.3 admin-system フロントエンド禁止

**Phase1 の `recerdo-admin-system` では Rails コードを生成してはならない。**  
Phase1 は必ず Next.js 15 + shadcn/ui + TypeScript を使用すること。  
Rails の追加は `[Stage1-Phase3] Rails 8 Admin Bundle` Issue で明示指示がある場合のみ。

---

## 4. 必須実装パターン

### 4.1 Idempotency Key（冪等性）

全ての更新系 API (`POST` / `PUT` / `PATCH` / `DELETE`) で必須:

```go
// リクエストヘッダから取得
idempotencyKey := r.Header.Get("Idempotency-Key")
if idempotencyKey == "" {
    return nil, ErrMissingIdempotencyKey
}

// Redis で処理済みチェック
cached, err := cache.Get(ctx, "idempotency:"+idempotencyKey)
if err == nil && cached != "" {
    return unmarshalCachedResponse(cached), nil
}
```

### 4.2 Transactional Outbox パターン

DB 更新とイベント発行の原子性を保証する:

```go
// トランザクション内で DB 更新と Outbox 挿入を同時に実行
tx.Create(&entity)
tx.Create(&OutboxEvent{
    AggregateID: entity.ID,
    EventType:   "album.created",
    Payload:     marshalPayload(entity),
})
// → Outbox Worker が非同期でキューに送信
```

### 4.3 Circuit Breaker

外部サービス呼び出し時に障害の連鎖を防ぐ:

```go
// sony/gobreaker または go-resilience/breaker を使用
cb := gobreaker.NewCircuitBreaker(gobreaker.Settings{
    MaxRequests: 5,
    Interval:    30 * time.Second,
    Timeout:     60 * time.Second,
})
result, err := cb.Execute(func() (interface{}, error) {
    return externalService.Call(ctx, input)
})
```

---

## 5. TDD 必須義務 (AI エージェント向け最重要ルール)

> **出典**: [tdd-process.md](core/tdd-process.md), Issue #41

### 5.1 Red-Green-Refactor の厳守

**AIエージェントは以下の順序で必ず実施すること:**

1. **先行テスト実装** → テストを書いてから実装コードを書く
2. **Red 確認** → `go test ./...` で `FAIL` を確認・GitHub Actions URL を記録
3. **実装** → テストを通過させる最小限の実装
4. **Green 確認** → `PASS` + カバレッジを確認・GitHub Actions URL を記録
5. **PR 提出** → Red log + Green log + Coverage を PR body に添付

### 5.2 PR body 必須項目

```markdown
## TDD 証跡（必須）

### Red log（修正前: 失敗確認）
<details><summary>失敗ログを貼付</summary>
（FAIL ログまたは N/A - 新規実装）
</details>

### Green log（修正後: 成功確認）
<details><summary>成功ログを貼付</summary>
（PASS + カバレッジ値）
</details>

### Coverage
- Line coverage: __%（閾値: ≥ 80%）
- Branch coverage: __%（閾値: ≥ 70%）
```

### 5.3 カバレッジ閾値

| 言語 | Line Coverage | Branch Coverage |
|---|---|---|
| Go | **≥ 80%** | **≥ 70%** |
| TypeScript | **≥ 80%** | **≥ 70%** |
| Swift | **≥ 80%** | — |
| Kotlin | **≥ 80%** | **≥ 70%** |

### 5.4 禁止行為

- Red ログなしで「テスト済み」と主張すること
- `t.Skip()` / `it.skip()` を理由なく使用すること
- 空のテスト関数を含む PR を提出すること
- カバレッジ水増しのために意味のない assertion を追加すること (`assert(true)` 等)

---

## 6. セキュリティ要件

### 6.1 認証・認可

- 全ての非公開 API で JWT トークン検証（AWS Cognito JWKS / RS256）ミドルウェアを適用すること
- JWT の `alg` フィールドが RS256 であることを検証すること (`alg: none` 攻撃対策)
- リソースへのアクセスは `owner_id` と認証ユーザーの ID を必ず比較すること (IDOR 対策)
- JWT 保存戦略: Cognito Hosted UI の制約により **localStorage** を基本方針とする

### 6.2 PII 保護

- ログにメールアドレス・電話番号・パスワード・フルネームを**絶対に出力しない**こと
- API レスポンスに不要な PII を含めないこと
- エラーメッセージに内部実装詳細を含めないこと

### 6.3 Trojan Source 攻撃防止

ソースコードに以下の文字を混入させてはならない:
- BiDi 制御文字 (U+202A-U+202E, U+2066-U+2069)
- Zero Width Space (U+200B), Zero Width Joiner (U+200D)

### 6.4 通信

- 全外部通信で TLS 1.2+ を強制すること
- Postfix SMTP は STARTTLS (`smtpd_tls_security_level=encrypt`) を必須とすること

---

## 7. MariaDB 10.11 互換性要件

全てのマイグレーションと GORM モデルは MySQL 8.0 + **MariaDB 10.11** 両方でテストすること。

**利用可能な機能**: `WINDOW 関数`, `CTE`, `JSON 型`, `GENERATED COLUMN`, `CHECK 制約`  
**利用禁止** (MySQL 固有): `JSON_TABLE`, `SELECT ... FOR UPDATE SKIP LOCKED`

CI テスト設定:
```yaml
services:
  mariadb:
    image: mariadb:10.11
    env:
      MARIADB_ROOT_PASSWORD: root
      MARIADB_DATABASE: recerdo_test
```

---

## 8. バイブコーディング委譲可能 vs 手動レビュー必須

### AI に委譲可能（適性：高）
- REST API エンドポイントの実装
- GORM モデル定義・マイグレーション（MariaDB 10.11 互換チェック付き）
- バリデーションロジック
- 単体テスト生成（TDD 義務に従うこと）
- Docker Compose 設定
- API ドキュメント生成
- PR テンプレートへの TDD 証跡追加

### 人間による手動レビュー必須（適性：低〜中）
- JWT 検証ミドルウェア・セキュリティ関連ロジック
- 暗号化・ハッシュ処理の実装
- Postfix/Dovecot/Rspamd 設定
- Garage / OCI Object Storage アダプタ境界の実装
- 本番セキュリティ設定・インフラ権限設計
- DB スキーマ破壊的変更 (Zero-downtime: gh-ost を使用)

### エスカレーション必須（独断禁止）

以下の場合は新規 Issue を起票してバックログとし、実装をスキップすること:
- アーキテクチャの根本的変更（DB スキーマの破壊的変更）
- 仕様が曖昧で複数の設計方針が考えられる場合
- 既存のビジネスロジックと著しく矛盾する修正が必要な場合

---

## 9. 重要なオーケストレーター決定事項 (2026-04-20)

| 決定事項 | 内容 |
|---|---|
| Android リポジトリ | `recerdo-android-dart` → `recerdo-android` (Kotlin + Jetpack Compose) |
| JWT 保存戦略 | Cognito Hosted UI 制約により **localStorage** 基本方針 |
| カバレッジ閾値 | **80%** に統一 (旧: 60%) |
| admin-system Phase1 | **Next.js 15 + shadcn/ui** (Rails は Phase3) |
| DB バージョン | **MariaDB 10.11** 互換 (旧: 10.6) |
| TDD プロセス | Red log + Green log + Coverage の 3 点証跡が全 PR に必須 |

---

## 10. 仕様書リンク集

| ドキュメント | URL |
|---|---|
| PoC/Beta スコープ定義 | [poc-beta-scope.md](core/poc-beta-scope.md) |
| 基本的方針 (ポリシー) | [policy.md](core/policy.md) |
| 開発ワークフロー | [workflow.md](core/workflow.md) |
| TDD Red→Green プロセス | [tdd-process.md](core/tdd-process.md) |
| リポジトリ構成 (Gap Analysis) | [repo-inventory.md](core/repo-inventory.md) |
| タスク依存関係マトリクス | [task-dependency-matrix.md](core/task-dependency-matrix.md) |
| Bootstrap チェックリスト | [bootstrap-checklist.md](core/bootstrap-checklist.md) |
| API Gateway 設計 | [api-gateway-design.md](core/api-gateway-design.md) |
| Beta QA チェックリスト | [beta-qa-checklist.md](core/beta-qa-checklist.md) |
| セキュリティ監査チェックリスト | [security-audit-checklist.md](core/security-audit-checklist.md) |
| マイクロサービス設計 | [microservice/index.md](microservice/index.md) |
| クリーンアーキテクチャ設計 | [clean-architecture/index.md](clean-architecture/index.md) |

---

最終更新: 2026-04-22 (v2.0 — オーケストレーター決定 2026-04-20 反映)