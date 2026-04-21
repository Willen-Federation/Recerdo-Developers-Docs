# CLAUDE.md

## 目的
Recerdo 関連リポジトリで AI コーディングエージェントが共通で遵守する実装・品質・セキュリティ方針を定義する。

## アーキテクチャ原則
- クリーンアーキテクチャ（Port/Adapter）を採用する。
- Port 名は `AuthPort` / `CachePort` / `QueuePort` / `StoragePort` などドメイン中立名を使う。
- `S3*` / `SQS*` / `SES*` / `AWS*` などクラウドベンダ名を Port 名に使わない。
- Feature Flag は default OFF で実装し、段階的ロールアウトする。

## 禁止事項
- 仕様書・Issue にない破壊的仕様変更を独断で行わない。
- PII（email/phone/name）をログ出力しない。
- 平文認証情報をコミットしない。
- 空テスト・恒真テスト（実質検証なし）を追加しない。

## 必須実装パターン
- Write API は `Idempotency-Key` を受理する。
- 非同期連携は Outbox パターンを優先する。
- 外部 I/O は Retry + Circuit Breaker を前提にする。

## TDD / QA ルール
- Red-Green-Refactor を必須とする。
- PR には Red log / Green log / Coverage を含める。
- Bootstrap など新規実装で Red を示せない場合は `N/A - 新規実装` を明記する。
- Unit カバレッジは全言語で 80% 以上。

## セキュリティ要件
- JWT は署名検証・失効チェックを行う。
- Trojan Source 対策として BiDi / ZW 系不可視文字を混入させない。
- STARTTLS 必須要件を満たさない SMTP 実装を採用しない。

## 委譲可能タスク / 手動レビュー必須タスク
### AI へ委譲可能
- ドキュメント追加・更新
- 既存設計準拠の実装
- テスト不足の補完

### 手動レビュー必須
- 認証・認可ロジック変更
- 暗号・鍵管理変更
- DB マイグレーション戦略変更
- 外部公開 API の破壊的変更
