# スプリント報告: Issue 分解スプリント

**実施日**: 2026-04-20  
**担当**: Akira Kusama / Claude (Anthropic) Issue Writer Agent  
**対象**: Willen-Federation 配下 バックエンド 13 リポジトリ  
**参照 Tracker**: [Recerdo-Developers-Docs #21](https://github.com/Willen-Federation/Recerdo-Developers-Docs/issues/21)

---

## 概要

設計書 (DD: Design Documents) を元に、Recerdo バックエンド全 13 リポジトリにわたる GitHub Issue を網羅的に作成したスプリントです。  
アーキテクチャ図・ユースケース層・横断標準 (policy §8) を参照し、**315 Issue** を作成しました。

---

## 作成方針

### Issue 構造
- **Epic Issue** (M1/M2/M3 各 Milestone 別): サービスのロードマップを俯瞰するチケット
- **Feature Issue** (ユースケース単位): DD §3 のユースケースを 1 Issue に 1:1 対応
- **Cross-cutting Issue**: gRPC ハンドラ配線・Outbox Publisher・OTEL・Feature Flag 評価層 など横断実装
- **Test/Deploy Issue**: testcontainers 統合テスト・Dockerfile・CI ワークフロー

### Milestone 割当基準 (`docs/core/poc-beta-scope.md §2.2` 参照)
| 優先度 | Milestone |
|--------|-----------|
| P0 / P1 | Beta M1 — MVP |
| P1 後続 / P2 | Beta M2 — Public Beta |
| P2 / P3 | Beta M3 — GA Readiness |

### テンプレート準拠
`docs/core/workflow.md §3.1` Issue テンプレートに準拠:
- Context / User Story / Acceptance Criteria / 技術要件 / Test Plan / Feature Flag / Dependencies / References / DoD

### 横断標準の必須 AC
- **Write API**: `Idempotency-Key` ヘッダ受理 (policy §8.4)
- **ドメインイベント発行**: Transactional Outbox 経由 (policy §8.5)
- **PII 処理**: `security:review` ラベル + PII ログ禁止 AC
- **Feature Flag**: `<svc>.<feature>.enabled` 形式、default OFF

---

## 作成結果サマリー

**合計: 315 Issue (13 リポジトリ)**

| カテゴリ | 件数 |
|----------|------|
| Epic (M1/M2/M3) | 38 |
| Feature (ユースケース) | 164 |
| Cross-cutting | 88 |
| Test / Deploy | 25 |

---

## リポジトリ別詳細

| リポジトリ | Bootstrap | M1 Epic | M2 Epic | M3 Epic | 合計 |
|-----------|-----------|---------|---------|---------|------|
| recerdo-admin-system | [#1](https://github.com/Willen-Federation/recerdo-admin-system/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-admin-system/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-admin-system/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-admin-system/issues/4) | 25 |
| recerdo-album | [#1](https://github.com/Willen-Federation/recerdo-album/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-album/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-album/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-album/issues/4) | 24 |
| recerdo-audit | [#1](https://github.com/Willen-Federation/recerdo-audit/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-audit/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-audit/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-audit/issues/4) | 22 |
| recerdo-core | [#1](https://github.com/Willen-Federation/recerdo-core/issues/1) | [#3](https://github.com/Willen-Federation/recerdo-core/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-core/issues/4) | [#5](https://github.com/Willen-Federation/recerdo-core/issues/5) | 28 |
| recerdo-event | [#1](https://github.com/Willen-Federation/recerdo-event/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-event/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-event/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-event/issues/4) | 26 |
| recerdo-feature-flag | [#1](https://github.com/Willen-Federation/recerdo-feature-flag/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-feature-flag/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-feature-flag/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-feature-flag/issues/4) | 25 |
| recerdo-infra | [#1](https://github.com/Willen-Federation/recerdo-infra/issues/1) | [#3](https://github.com/Willen-Federation/recerdo-infra/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-infra/issues/4) | [#5](https://github.com/Willen-Federation/recerdo-infra/issues/5) | 25 |
| recerdo-notifications | [#1](https://github.com/Willen-Federation/recerdo-notifications/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-notifications/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-notifications/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-notifications/issues/4) | 25 |
| recerdo-permission-management | [#1](https://github.com/Willen-Federation/recerdo-permission-management/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-permission-management/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-permission-management/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-permission-management/issues/4) | 26 |
| recerdo-shared-lib | [#4](https://github.com/Willen-Federation/recerdo-shared-lib/issues/4) | [#5](https://github.com/Willen-Federation/recerdo-shared-lib/issues/5) | [#6](https://github.com/Willen-Federation/recerdo-shared-lib/issues/6) | — | 18 |
| recerdo-shared-proto | [#3](https://github.com/Willen-Federation/recerdo-shared-proto/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-shared-proto/issues/4) | [#5](https://github.com/Willen-Federation/recerdo-shared-proto/issues/5) | — | 17 |
| recerdo-storage | [#1](https://github.com/Willen-Federation/recerdo-storage/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-storage/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-storage/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-storage/issues/4) | 28 |
| recerdo-timeline | [#1](https://github.com/Willen-Federation/recerdo-timeline/issues/1) | [#2](https://github.com/Willen-Federation/recerdo-timeline/issues/2) | [#3](https://github.com/Willen-Federation/recerdo-timeline/issues/3) | [#4](https://github.com/Willen-Federation/recerdo-timeline/issues/4) | 26 |

---

## 検出事項・修正

### 検出事項 #1: events-svc.md ディレクトリツリーの命名規約違反

**ファイル**: `docs/microservice/events-svc.md` §5 ディレクトリ構造  
**内容**: ポリシー §4.2（禁止アダプタ名: `SQSAdapter` / `S3Adapter` 等）に対応する AWS 由来の命名を含むファイル名が DD に記載されていた

| 変更前 | 変更後 |
|--------|--------|
| `queue/sqs_publisher.go` | `queue/queue_publisher.go` |
| `sqs_consumer/` (ディレクトリ) | `queue_consumer/` |
| `notification/notification_sqs_adapter.go` | `notification/notification_queue_adapter.go` |

**対応**: 本 PR で修正済み。recerdo-event リポジトリの実装時は `QueuePort` / `AsynqQueueAdapter` (Go) または同等の非 AWS 命名を使用すること。

---

## 参考: Issue 作成プロセス

1. DD ファイル (`/tmp/recerdo-dd/`) を全読み → ユースケース列挙
2. `poc-beta-scope.md §2.2` で Milestone 割当
3. 13 エージェントを並列起動 (1 エージェント = 1 リポジトリ)
4. 各エージェントが sequential に Issue 作成 (重複防止のため並列作成禁止)
5. Epic 本文の Sub-issues リストを作成後に更新 (edit)
6. JSON ログ `/tmp/recerdo-issues/<repo>.json` に記録
7. Tracker #21 にスプリントサマリー追記

---

最終更新: 2026-04-20
