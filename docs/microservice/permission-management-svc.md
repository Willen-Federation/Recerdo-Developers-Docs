# Permission Management Service (recerdo-permission-management)

**作成者**: Akira · **作成日**: 2026-04-24 · **ステータス**: Draft

---

## 1. 概要

### 目的

Recerdo プラットフォーム全体の認可（Authorization）ロジックを一元管理する専用マイクロサービス。役割ベースアクセス制御（RBAC）と属性ベースアクセス制御（ABAC）を組み合わせ、リソースへの権限評価・付与・剥奪をリアルタイムに行う。Cache-first アーキテクチャで評価レイテンシ p99 < 10ms（キャッシュヒット）/ p99 < 50ms（キャッシュミス）を保証する。

### 境界

- **担当**: 役割付与・剥奪、権限評価、ポリシーバージョン管理、権限の階層継承、一括チェック、期限付き委任
- **対象外**: 認証（JWT 発行/検証 → recerdo-core）、ユーザー管理（→ recerdo-core）、特定サービス固有のビジネスルール（各サービスで実装）

---

## 2. ドメインモデル

| エンティティ    | 説明                                                     | 主要属性                                                                                  |
| --------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Role            | 権限のまとまり（admin, member, viewer, event_manager 等）| id (ULID), org_id, name, description, permissions[], created_at, updated_at               |
| RoleAssignment  | ユーザーへの役割付与記録                                 | id (ULID), org_id, user_id, role_id, resource_id?, expires_at?, granted_by, created_at   |
| ResourceACL     | リソースレベルの細粒度アクセス制御エントリ               | id (ULID), resource_type, resource_id, subject_type, subject_id, permissions[], created_at |
| PolicyVersion   | ポリシー定義のバージョン管理（ロールバック対応）         | id (ULID), org_id, version, definition (JSON), published_at, published_by                |
| OutboxEvent     | 権限変更の非同期通知用アウトボックス                     | id (ULID), event_type, payload (JSON), status, created_at, published_at?                  |

### 値オブジェクト

| 値オブジェクト  | 説明                                              | バリデーション                                              |
| --------------- | ------------------------------------------------- | ----------------------------------------------------------- |
| Permission      | アクション識別子 (`event:create`, `album:delete`) | `{resource}:{action}` 形式、英小文字・コロン・アンダースコアのみ |
| SubjectType     | 権限付与対象の種別                                | user / group / service_account のいずれか                  |
| ResourceType    | 権限が適用されるリソース種別                      | org / event / album / media / timeline / notification        |
| FailMode        | 評価サービス不可時の振る舞い                      | DENY_ALL（デフォルト）/ ALLOW_READONLY                       |

---

## 3. ユースケース

| ユースケース            | 説明                                              | 入力                             | 出力                       |
| ----------------------- | ------------------------------------------------- | -------------------------------- | -------------------------- |
| GrantRole               | ユーザーに役割を付与する                          | org_id, user_id, role_id, expires_at? | RoleAssignment            |
| RevokeRole              | ユーザーから役割を剥奪する                        | org_id, user_id, role_id         | void                       |
| EvaluatePermission      | 単一権限評価（allow/deny）                        | subject, resource, action        | bool + reason              |
| BatchCheckPermissions   | 複数権限を一括評価（最大 100 件）                 | []CheckRequest                   | []CheckResult              |
| ListRoles               | 組織内の役割一覧取得                              | org_id, pagination               | []Role                     |
| SeedDefaultRoles        | 組織作成時のデフォルト役割初期投入                | org_id                           | []Role                     |
| EvaluateABAC            | 属性ベース評価（time, ip, custom_attrs）          | context + policy                 | Decision                   |
| LogAuditEvent           | 権限変更・評価をアウトボックス経由で監査ログ送出  | event_type, payload              | void                       |
| SetHierarchyInheritance | 親ロールから子ロールへの権限継承設定              | parent_role_id, child_role_id    | HierarchyEntry             |
| BulkGrantRevoke         | 複数ユーザーへの一括付与・剥奪                    | []GrantRequest / []RevokeRequest | []Result                   |
| SetExpiryForAssignment  | 既存付与に有効期限を設定                          | assignment_id, expires_at        | RoleAssignment             |
| DelegatePermission      | ユーザーが自己権限の一部を別ユーザーに委任        | delegator_id, delegatee_id, permissions[], ttl | DelegationRecord |

---

## 4. Port / Adapter

| Port名                | 説明                                              | 実装（Beta）                              |
| --------------------- | ------------------------------------------------- | ----------------------------------------- |
| RoleRepositoryPort    | 役割・付与情報の永続化                            | GORM + MySQL 8.0                          |
| PolicyEvaluatorPort   | ポリシー評価エンジン（Casbin / OPA 等）           | Casbin v2 + MySQL adapter                 |
| CachePort             | 評価結果のキャッシュ（10min TTL）                 | Redis 7 (`SET NX EX`)                     |
| QueuePort             | 権限変更イベントの非同期配信                      | Redis BullMQ（Beta）/ OCI Queue（Prod）   |
| AuditEventPort        | 監査ログ出力                                      | アウトボックス → Loki                     |
| FeatureFlagPort       | フラグ評価（Flipt + OpenFeature SDK）             | go.flipt.io/flipt/sdk/go                  |
| IdempotencyStorePort  | 冪等キー管理（重複付与・剥奪防止）                | Redis（`SET NX EX 86400`）                |
| RateLimiterPort       | Admin API のレート制限（per-user 60 req/min）     | Redis sliding window                      |

---

## 5. SLI / SLO

| 指標                      | 目標                                       |
| ------------------------- | ------------------------------------------ |
| EvaluatePermission レイテンシ（キャッシュヒット） | p99 < 10ms       |
| EvaluatePermission レイテンシ（キャッシュミス）  | p99 < 50ms       |
| BatchCheckPermissions レイテンシ (100件)         | p99 < 100ms      |
| 可用性                    | 99.95%（月次 SLO）                         |
| キャッシュヒット率        | ≥ 80%                                      |
| エラー率（5xx）           | < 0.1%                                     |

---

## 6. 外部依存

| サービス    | 用途                                   | Beta 接続先                           |
| ----------- | -------------------------------------- | ------------------------------------- |
| MySQL 8.0   | roles, role_assignments, resource_acls, outbox_events テーブル | `recerdo-permission-db:3306` |
| Redis 7     | CachePort / IdempotencyStorePort / RateLimiterPort | `recerdo-redis:6379`   |
| Flipt       | FeatureFlagPort                        | `recerdo-flipt:9000` (gRPC)           |
| OCI Queue   | QueuePort（Prod）                      | OCI Queue エンドポイント              |

---

## 7. Failure Modes

| シナリオ              | 振る舞い                                                        |
| --------------------- | --------------------------------------------------------------- |
| DB 接続断             | キャッシュから評価を試みる。キャッシュミス時は `fail_mode` に従う |
| Redis 接続断          | DB から直接評価（レイテンシ増加を許容）                         |
| Flipt 接続断          | フラグ評価はデフォルト値（安全側）を返す                        |
| `fail_mode=DENY_ALL`  | 評価不能時は全権限を拒否（デフォルト）                          |
| `fail_mode=ALLOW_READONLY` | 読み取り系権限のみ許可                                    |
| サーキットブレーカー  | 連続 5 回失敗で Open → 30s 後に Half-Open → 成功で Closed      |

---

## 8. API エンドポイント

| Method | Path                                    | 説明                       |
| ------ | --------------------------------------- | -------------------------- |
| POST   | `/v1/permissions/evaluate`              | 単一権限評価               |
| POST   | `/v1/permissions/batch-evaluate`        | 一括権限評価（最大 100 件）|
| POST   | `/v1/roles`                             | 役割作成                   |
| GET    | `/v1/roles`                             | 役割一覧                   |
| POST   | `/v1/roles/{role_id}/assignments`       | 役割付与                   |
| DELETE | `/v1/roles/{role_id}/assignments/{uid}` | 役割剥奪                   |
| POST   | `/v1/roles/{role_id}/delegate`          | 権限委任                   |
| GET    | `/v1/healthz`                           | Liveness probe             |
| GET    | `/v1/readyz`                            | Readiness probe            |
| GET    | `/metrics`                              | Prometheus メトリクス      |

gRPC サービス: `permission.PermissionService/Check`（各マイクロサービスから内部利用）

---

## 9. 関連ドキュメント

- [policy.md §5 PII](../core/policy.md)
- [environment-abstraction.md §4 Feature Flag](../core/environment-abstraction.md)
- [call-matrix.md](./call-matrix.md)
- [feature-flag-system.md](./feature-flag-system.md)
- [clean-architecture/permission-management-svc.md](../clean-architecture/permission-management-svc.md)
