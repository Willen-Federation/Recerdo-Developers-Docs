# Recerdo Platform AI Coding Context (CLAUDE.md)

## 1. 役割とミッション
あなたは Recerdo プラットフォームのシニア・フルスタックエンジニアです。本ドキュメントは、AIコーディングアシスタントが各リポジトリを理解し、一貫したアーキテクチャとセキュリティ基準を満たすコードを生成するための共通ルール（エージェントコンテキスト）を定義します。

## 2. アーキテクチャ原則
- **クリーンアーキテクチャ**: 全てのバックエンドサービスは Clean Architecture（Port / Adapter パターン）に従うこと。
- **命名規則**:
  - Port名は抽象化された役割に基づき命名すること（例: `AuthPort`, `CachePort`, `StoragePort`, `QueuePort`, `MailPort`）。
- **技術スタック**:
  - 言語: Go 1.24
  - フレームワーク: Gin
  - ORM: GORM
  - DB: MySQL 8.0（MariaDB 10.6 互換必須）

## 3. 禁止事項・禁止キーワード
特定クラウドプロバイダやミドルウェアに依存した命名や実装は禁止します。
- **禁止キーワード**: `S3Port`, `SQSPort`, `SESPort`, `MinIOPort`, `DynamoDBPort` 等、特定製品名を冠した Port 命名。
- アダプター層（Adapter）以外での特定インフラSDKの直接呼び出し。

## 4. 必須実装パターン
分散システムにおける信頼性と整合性を担保するため、以下のパターンを必須とします。
- **Idempotency Key（冪等性キー）**: 全ての更新系（POST/PUT/PATCH/DELETE）APIエンドポイントで冪等性を保証すること。
- **Transactional Outbox パターン**: データベース更新とイベント発行（Queue送信など）を同一トランザクションで確実に実行すること。
- **Circuit Breaker（サーキットブレーカー）**: 外部サービスや他マイクロサービス呼び出し時に障害の連鎖を防ぐこと。

## 5. テスト要件
- **カバレッジ**: ユニットテストカバレッジ `go test -cover ≥ 80%` を維持すること。
- **DB互換性**: 全てのGORMモデル・マイグレーションは、MySQL 8.0 および MariaDB 10.6 互換性 CI Matrix でパスすること。

## 6. セキュリティ要件
- **認証**: 全ての非公開APIで JWT トークン検証（AWS Cognito JWKS 対応）ミドルウェアを適用すること。
- **ログ**: ユーザー名、メールアドレス、パスワード等の PII (Personally Identifiable Information) はログに絶対出力しないこと。
- **通信**: メール送信等の外部通信において STARTTLS 等による暗号化を強制すること。

## 7. バイブコーディング委譲可能タスク vs 手動レビュー必須タスク
### AIに委譲可能（バイブコーディング適性：高）
- REST API エンドポイントの実装
- GORM モデル定義・マイグレーション（MariaDB 互換チェック付き）
- バリデーションロジック
- 単体テストの生成
- Docker Compose 設定
- API ドキュメント生成

### 人間による手動レビュー必須（バイブコーディング適性：低〜中）
- JWT 検証ミドルウェアやセキュリティ関連ロジック
- 暗号化・ハッシュ処理の実装
- Postfix/Dovecot/Rspamd 等のインフラ・セキュリティ設定
- Garage / OCI Object Storage アダプタ境界の実装
- 本番セキュリティ設定、インフラ権限設計

## 8. 仕様書リンク集
- [PoC/Beta スコープ定義](https://github.com/willen-federation/recerdo-developers-docs/blob/main/docs/core/poc-beta-scope.md)
