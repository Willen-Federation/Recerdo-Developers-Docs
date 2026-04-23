# Permission Management Service — Clean Architecture

**作成者**: Akira · **作成日**: 2026-04-24 · **ステータス**: Draft

---

## 1. レイヤー構成

```
recerdo-permission-management/
├── cmd/
│   └── server/
│       └── main.go                          # エントリポイント
├── internal/
│   ├── domain/                              # ドメイン層（外部依存ゼロ）
│   │   ├── entity/
│   │   │   ├── role.go
│   │   │   ├── role_assignment.go
│   │   │   ├── resource_acl.go
│   │   │   ├── policy_version.go
│   │   │   └── outbox_event.go
│   │   ├── port/
│   │   │   ├── repository.go                # RoleRepositoryPort, ACLRepositoryPort
│   │   │   └── service.go                   # CachePort, QueuePort, AuditEventPort,
│   │   │                                    # FeatureFlagPort, IdempotencyStorePort,
│   │   │                                    # PolicyEvaluatorPort, RateLimiterPort
│   │   └── errors/
│   │       └── errors.go
│   ├── usecase/                             # アプリケーション層
│   │   ├── grant_role.go
│   │   ├── revoke_role.go
│   │   ├── evaluate_permission.go
│   │   ├── batch_check_permissions.go
│   │   ├── list_roles.go
│   │   ├── seed_default_roles.go
│   │   ├── evaluate_abac.go
│   │   ├── log_audit_event.go
│   │   ├── set_hierarchy_inheritance.go
│   │   ├── bulk_grant_revoke.go
│   │   ├── set_expiry_for_assignment.go
│   │   └── delegate_permission.go
│   ├── adapter/                             # アダプター層
│   │   ├── http/
│   │   │   ├── handler.go                   # REST API ハンドラー
│   │   │   └── middleware/
│   │   │       ├── auth.go                  # JWT 検証（Cognito JWKS）
│   │   │       └── ratelimit.go
│   │   ├── grpc/
│   │   │   └── server.go                    # gRPC PermissionService/Check
│   │   └── repository/
│   │       ├── role_repository.go           # GORM MySQL 実装
│   │       └── acl_repository.go
│   └── infra/                               # インフラ層
│       ├── config/
│       │   └── config.go                    # 環境変数読み込み
│       ├── db/
│       │   └── mysql.go                     # MySQL GORM セットアップ
│       ├── cache/
│       │   └── redis_cache.go               # CachePort 実装
│       ├── queue/
│       │   └── redis_queue.go               # QueuePort 実装（BullMQ / OCI Queue）
│       ├── featureflag/
│       │   └── flipt_provider.go            # FeatureFlagPort 実装
│       ├── policy/
│       │   └── casbin_evaluator.go          # PolicyEvaluatorPort 実装
│       ├── idempotency/
│       │   └── redis_idempotency.go         # IdempotencyStorePort 実装
│       ├── ratelimit/
│       │   └── redis_limiter.go             # RateLimiterPort 実装
│       └── observability/
│           ├── metrics.go                   # Prometheus メトリクス
│           └── tracing.go                   # OTEL トレーシング
```

---

## 2. 依存関係フロー

```
cmd → usecase → domain/port
                     ↑
              infra/adapter (実装)
```

- `domain/` は外部パッケージをインポートしない
- `usecase/` は `domain/port` のインターフェースのみに依存
- `infra/` と `adapter/` は具体的な実装を持つ
- DI は `cmd/server/main.go` で手動ワイヤリング

---

## 3. ユースケース詳細

### EvaluatePermission

```
1. IdempotencyStorePort.CheckRequest(key) → キャッシュヒット時即返却
2. CachePort.Get(subject+resource+action) → ヒット時即返却
3. PolicyEvaluatorPort.Evaluate(subject, resource, action) → DB クエリ
4. CachePort.Set(result, TTL=10min)
5. AuditEventPort.Log(eval_event)
6. return Decision{Allowed: bool, Reason: string}
```

### BatchCheckPermissions

```
1. 最大 100 件を goroutine pool (workers=10) で並列評価
2. 各評価は EvaluatePermission と同フロー
3. 全結果集約して返却
4. total latency p99 < 100ms 保証
```

---

## 4. gRPC インターフェース

```protobuf
syntax = "proto3";
package permission.v1;

service PermissionService {
  rpc Check(CheckRequest) returns (CheckResponse);
  rpc BatchCheck(BatchCheckRequest) returns (BatchCheckResponse);
}

message CheckRequest {
  string action      = 1;  // e.g. "event:create"
  string org_id      = 2;
  string resource_id = 3;
  string user_id     = 4;
}

message CheckResponse {
  bool   allowed = 1;
  string reason  = 2;
}
```

---

## 5. 観測性

| メトリクス                                | 説明                          |
| ----------------------------------------- | ----------------------------- |
| `permission.evaluate.duration_seconds`    | 評価レイテンシヒストグラム    |
| `permission.cache.hit_total`              | キャッシュヒット数            |
| `permission.cache.miss_total`             | キャッシュミス数              |
| `permission.evaluate.error_total`         | 評価エラー数                  |
| `permission.rate_limit.exceeded_total`    | レート制限超過数              |

OTEL span: `permission.evaluate`, `permission.cache.get`, `permission.db.query`

---

## 6. テスト戦略

| レイヤー       | 手法                                    | カバレッジ目標 |
| -------------- | --------------------------------------- | -------------- |
| domain/entity  | ユニットテスト（外部依存なし）          | 100%           |
| usecase        | モック Port でユニットテスト            | ≥ 80%          |
| adapter/http   | httptest でエンドポイントテスト         | ≥ 70%          |
| adapter/grpc   | grpc.Dial + bufconn でインテグレーション| ≥ 70%          |
| infra/cache    | miniredis                               | ≥ 80%          |
| infra/policy   | Casbin メモリアダプター                 | ≥ 80%          |
| E2E            | testcontainers (MySQL + Redis)          | 主要フロー     |

---

## 7. 関連ドキュメント

- [microservice/permission-management-svc.md](../microservice/permission-management-svc.md)
- [microservice/call-matrix.md](../microservice/call-matrix.md)
- [core/policy.md](../core/policy.md)
