---
title: "Permission Microservice Design"
weight: 14
---

# Permission Microservice (recuerdo-permission-svc)

**作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoの全マイクロサービスにおける権限管理の単一ソース・オブ・トゥルースを提供する。システムロール・組織ロール・機能フラグ・レート制限・データ地域制御・監査ログを一元管理し、すべてのサービスがgRPC経由で同期的に権限チェックを行えるようにする。APIゲートウェイおよび各マイクロサービスが本サービスを通じてアクセス制御を行うことで、権限ロジックの重複実装を排除し、将来のサブスクリプションや広告モデル導入の基盤とする。

### ビジネスコンテキスト

recuerdoは旧友・旧グループとの再接続と思い出の保存を核とするソーシャルメモリアプリ。持続可能なビジネスモデル（サブスクリプション・広告・メディアリカバリ課金）を実現するには、まず堅牢な権限基盤が必要。

Key User Stories:

- ユーザーとして、自分のデータが居住国の法規制(GDPR等)に準拠した地域に保存されていることを確認したい
- 組織オーナーとして、グループメンバーの機能アクセスを細かく制御したい
- 管理者として、誰がいつどのデータにアクセスしたか監査ログで確認したい
- サブスクリプションティアに応じて、利用できるストレージ容量・機能が変わることを期待する

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ | 説明 | 主要属性 |
| --- | --- | --- |
| UserPermission | ユーザーのシステムレベル権限を管理 | user_id, system_role, status, subscription_tier, geo_region, created_at, updated_at |
| OrgPermission | 組織・グループ内でのユーザーロールを管理 | org_id, user_id, org_role, feature_flags, created_at, updated_at |
| FeaturePolicy | サブスクリプションティア別の機能・制限ポリシー | tier, feature_key, enabled, rate_limit, storage_quota_mb, updated_at |
| GeoPolicy | データ地域制御ポリシー（GDPR等対応） | region_code, allowed_storage_regions, data_residency_required, updated_at |
| AuditLog | 全権限チェック・変更の監査ログ | id, actor_user_id, action, resource_type, resource_id, result, ip_address, timestamp |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーションルール |
| --- | --- | --- |
| SystemRole | システム全体のロール (SUPERUSER / USER / GUEST / NONE) | 列挙値のみ許可。未知の値は NONE 扱い |
| OrgRole | 組織内ロール (OWNER / ADMIN / MEMBER / GUEST) | 列挙値のみ許可。組織に対し OWNER は最低1名必須 |
| SubscriptionTier | サブスクリプションプラン (FREE / BASIC / PREMIUM) | 列挙値のみ許可 |
| GeoRegion | データ保存地域コード (e.g. JP, EU, US) | ISO 3166-1 alpha-2 準拠、空文字不可 |
| RateLimit | API レート制限値 | requests_per_minute > 0, burst_size > 0 |

### ドメインルール / 不変条件

- 組織には必ず1名以上のOWNERが存在しなければならない
- SUPERUSER以外のユーザーは自分のsystem_roleを自己昇格できない
- status=SUSPENDEDのユーザーはすべての機能へのアクセスを拒否される
- GEOPolicyに違反するデータ保存リージョンへの書き込みは拒否される
- FeaturePolicyのrate_limitを超えるリクエストは429エラーで拒否される
- すべての権限チェック結果（許可・拒否を問わず）はAuditLogに記録される
- サブスクリプションtiereのdowngradeは既存データに影響しないが、新規アップロードは制限される

### ドメインイベント

| イベント | トリガー | 主要ペイロード |
| --- | --- | --- |
| PermissionGranted | 権限チェックが許可された | user_id, resource_type, resource_id, action, timestamp |
| PermissionDenied | 権限チェックが拒否された | user_id, resource_type, resource_id, action, reason, timestamp |
| UserRoleChanged | システムロールまたは組織ロールが変更された | actor_id, target_user_id, org_id?, old_role, new_role, timestamp |
| SubscriptionTierChanged | サブスクリプションティアが変更された | user_id, old_tier, new_tier, effective_at |
| RateLimitExceeded | レート制限を超過した | user_id, feature_key, limit, timestamp |
| GeoPolicyViolationDetected | 地域ポリシー違反が検出された | user_id, requested_region, allowed_regions, resource_type, timestamp |

### エンティティ定義（コードスケッチ）

```go
type SystemRole string
const (
    RoleSuperUser SystemRole = "SUPERUSER"
    RoleUser      SystemRole = "USER"
    RoleGuest     SystemRole = "GUEST"
    RoleNone      SystemRole = "NONE"
)

type OrgRole string
const (
    OrgOwner  OrgRole = "OWNER"
    OrgAdmin  OrgRole = "ADMIN"
    OrgMember OrgRole = "MEMBER"
    OrgGuest  OrgRole = "GUEST"
)

type UserPermission struct {
    UserID           string
    SystemRole       SystemRole
    Status           string // ACTIVE | SUSPENDED
    SubscriptionTier string // FREE | BASIC | PREMIUM
    GeoRegion        string // ISO 3166-1 alpha-2
    CreatedAt        time.Time
    UpdatedAt        time.Time
}

func NewUserPermission(userID, geoRegion string) (*UserPermission, error) {
    if userID == "" { return nil, ErrInvalidUserID }
    if !isValidGeoRegion(geoRegion) { return nil, ErrInvalidGeoRegion }
    return &UserPermission{
        UserID:           userID,
        SystemRole:       RoleUser,
        Status:           "ACTIVE",
        SubscriptionTier: "FREE",
        GeoRegion:        geoRegion,
        CreatedAt:        time.Now(),
        UpdatedAt:        time.Now(),
    }, nil
}

func (u *UserPermission) CanAccess(feature string, policy *FeaturePolicy) bool {
    if u.Status == "SUSPENDED" { return false }
    if u.SystemRole == RoleSuperUser { return true }
    return policy.IsEnabled(u.SubscriptionTier, feature)
}

func (u *UserPermission) Suspend() error {
    if u.SystemRole == RoleSuperUser {
        return ErrCannotSuspendSuperUser
    }
    u.Status = "SUSPENDED"
    u.UpdatedAt = time.Now()
    return nil
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力DTO | 出力DTO | 説明 |
| --- | --- | --- | --- |
| CheckPermission | CheckPermissionInput{user_id, org_id?, action, resource_type, resource_id} | CheckPermissionOutput{allowed, reason, audit_id} | 権限チェックの核心ユースケース。gRPC経由で同期的に呼び出される |
| GetUserPolicy | GetUserPolicyInput{user_id} | GetUserPolicyOutput{system_role, subscription_tier, geo_region, feature_flags, rate_limits} | ユーザーの全ポリシー情報を取得 |
| AssignOrgRole | AssignOrgRoleInput{actor_id, target_user_id, org_id, role} | AssignOrgRoleOutput{success, event_id} | 組織内ロールを割り当て・変更する |
| UpdateSubscriptionTier | UpdateSubscriptionTierInput{user_id, new_tier, effective_at} | UpdateSubscriptionTierOutput{success} | サブスクリプションティア変更 |
| ValidateGeoPolicy | ValidateGeoPolicyInput{user_id, target_storage_region, resource_type} | ValidateGeoPolicyOutput{allowed, required_region} | データ保存前に地域ポリシーを検証 |
| GetAuditLog | GetAuditLogInput{user_id?, org_id?, from, to, page} | GetAuditLogOutput{logs[], total} | 監査ログを取得する |
| SuspendUser | SuspendUserInput{actor_id, target_user_id, reason} | SuspendUserOutput{success} | ユーザーをサスペンドする |

### CheckPermission — 主要ユースケース詳細

**トリガー**: APIゲートウェイまたは各マイクロサービスがgRPC CheckPermission RPCを呼び出す

**フロー**:

1. Input validation: user_id, action, resource_typeが空でないことを確認
2. UserPermissionRepository.FindByUserID(user_id) でユーザーポリシーを取得 — 見つからない場合 → DENIED (reason: USER_NOT_FOUND)
3. ユーザーStatus == SUSPENDED → DENIED (reason: ACCOUNT_SUSPENDED)
4. SystemRole == SUPERUSER → ALLOWED (全アクセス許可)
5. org_idが指定されている場合: OrgPermissionRepository.FindByOrgAndUser(org_id, user_id) で組織ロール取得
6. FeaturePolicyRepository.FindByTierAndFeature(tier, resource_type) で機能ポリシー取得
7. RateLimiter.Check(user_id, feature_key) でレート制限チェック
8. ALLOWED → AuditLogRepository.Save(audit_log) で結果を非同期記録

### リポジトリ・サービスポート（インターフェース）

```go
// Repository Ports
type UserPermissionRepository interface {
    FindByUserID(ctx context.Context, userID string) (*UserPermission, error)
    Save(ctx context.Context, perm *UserPermission) error
    UpdateTier(ctx context.Context, userID, tier string) error
    UpdateStatus(ctx context.Context, userID, status string) error
}

type OrgPermissionRepository interface {
    FindByOrgAndUser(ctx context.Context, orgID, userID string) (*OrgPermission, error)
    FindByOrg(ctx context.Context, orgID string) ([]*OrgPermission, error)
    Save(ctx context.Context, perm *OrgPermission) error
    Delete(ctx context.Context, orgID, userID string) error
}

type FeaturePolicyRepository interface {
    FindByTierAndFeature(ctx context.Context, tier, featureKey string) (*FeaturePolicy, error)
    FindAllByTier(ctx context.Context, tier string) ([]*FeaturePolicy, error)
}

type AuditLogRepository interface {
    Save(ctx context.Context, log *AuditLog) error
    FindByFilter(ctx context.Context, filter AuditFilter) ([]*AuditLog, int, error)
}

// Service Ports
type CachePort interface {
    Get(ctx context.Context, key string) ([]byte, error)
    Set(ctx context.Context, key string, value []byte, ttl time.Duration) error
    Delete(ctx context.Context, key string) error
}

type RateLimiterPort interface {
    Check(ctx context.Context, userID, featureKey string, limit RateLimit) (bool, error)
}

type EventPublisherPort interface {
    Publish(ctx context.Context, event DomainEvent) error
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ | ルート/トリガー | ユースケース |
| --- | --- | --- |
| PermissionGRPCServer | gRPC: CheckPermission RPC | CheckPermissionUseCase |
| PermissionGRPCServer | gRPC: GetUserPolicy RPC | GetUserPolicyUseCase |
| PermissionGRPCServer | gRPC: ValidateGeoPolicy RPC | ValidateGeoPolicyUseCase |
| OrgRoleHTTPHandler | POST /internal/orgs/{org_id}/members/{user_id}/role | AssignOrgRoleUseCase |
| SubscriptionHTTPHandler | POST /internal/users/{user_id}/subscription | UpdateSubscriptionTierUseCase |
| AuditLogHTTPHandler | GET /internal/audit-logs | GetAuditLogUseCase |
| UserAdminHTTPHandler | POST /internal/users/{user_id}/suspend | SuspendUserUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス | データストア |
| --- | --- | --- |
| UserPermissionRepository | MySQLUserPermissionRepository | MySQL (permission DB) |
| OrgPermissionRepository | MySQLOrgPermissionRepository | MySQL (permission DB) |
| FeaturePolicyRepository | MySQLFeaturePolicyRepository | MySQL (permission DB) |
| AuditLogRepository | MySQLAuditLogRepository | MySQL (audit DB, write-optimized) |
| CachePort | RedisCache | Redis (TTL-based cache) |
| RateLimiterPort | RedisRateLimiter | Redis (sliding window counter) |

## 5. インフラストラクチャ層

### Webフレームワーク

Go 1.22 + google.golang.org/grpc (gRPC server) + net/http (internal REST endpoints)

### データベース

MySQL 8.0 (go-sql-driver/mysql), connection pool max 30. Redis 7.x for cache and rate limiting (go-redis/v9).

### 主要ライブラリ・SDK

| ライブラリ | 目的 | レイヤー |
| --- | --- | --- |
| google.golang.org/grpc | gRPC サーバー・クライアント | Infrastructure |
| go-redis/v9 | Redis キャッシュ・レート制限 | Infrastructure |
| go-sql-driver/mysql | MySQL ドライバ | Infrastructure |
| aws-sdk-go-v2/service/sqs | SQS イベント発行 | Infrastructure |
| golang-jwt/jwt/v5 | JWT パース・検証 | Adapter |
| uber-go/fx | 依存性注入コンテナ | Infrastructure |
| uber-go/zap | 構造化ログ | Infrastructure |
| prometheus/client_golang | メトリクス収集 | Infrastructure |

### 依存性注入

```go
fx.Provide(
    NewMySQLUserPermissionRepository,   // → UserPermissionRepository
    NewMySQLOrgPermissionRepository,    // → OrgPermissionRepository
    NewRedisCache,                       // → CachePort
    NewRedisRateLimiter,                 // → RateLimiterPort
    NewSQSEventPublisher,               // → EventPublisherPort
    NewCheckPermissionUseCase,
    NewGetUserPolicyUseCase,
    NewPermissionGRPCServer,
)
```

## 6. ディレクトリ構成

```
recuerdo-permission-svc/
├── cmd/server/main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── user_permission.go
│   │   │   ├── org_permission.go
│   │   │   ├── feature_policy.go
│   │   │   ├── geo_policy.go
│   │   │   └── audit_log.go
│   │   ├── valueobject/
│   │   │   ├── system_role.go
│   │   │   ├── org_role.go
│   │   │   └── rate_limit.go
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── check_permission.go
│   │   ├── get_user_policy.go
│   │   ├── assign_org_role.go
│   │   ├── update_subscription.go
│   │   ├── validate_geo_policy.go
│   │   ├── get_audit_log.go
│   │   ├── suspend_user.go
│   │   └── port/
│   │       ├── repository.go
│   │       └── service.go
│   ├── adapter/
│   │   ├── grpc/permission_server.go
│   │   ├── http/
│   │   │   ├── org_role_handler.go
│   │   │   ├── subscription_handler.go
│   │   │   └── audit_log_handler.go
│   │   └── queue/subscription_consumer.go
│   └── infrastructure/
│       ├── mysql/
│       ├── redis/
│       ├── sqs/
│       └── cognito/
├── proto/permission/v1/permission.proto
├── migrations/
├── config/
└── docker/Dockerfile
```

## 7. テスト戦略

| レイヤー | テスト種別 | モック戦略 |
| --- | --- | --- |
| Domain (entity/valueobject) | Unit test (go test) | 外部依存なし。純粋なGoテスト |
| UseCase | Unit test (go test) | PortインターフェースをtestifyのMockでモック |
| Adapter (gRPC/HTTP) | Integration test | UseCaseをモック。grpc/testingでgRPCテスト |
| Infrastructure (MySQL/Redis) | Integration test | testcontainers-goで実際のMySQL/Redisコンテナを起動 |
| E2E | E2E test | 実際のgRPCサーバーを起動し、全レイヤーを通したシナリオテスト |

### テストコード例

```go
func TestUserPermission_CanAccess_SuspendedUser(t *testing.T) {
    user := &UserPermission{
        UserID: "user-123", SystemRole: RoleUser,
        Status: "SUSPENDED", SubscriptionTier: "PREMIUM",
    }
    policy := &FeaturePolicy{Enabled: true}
    assert.False(t, user.CanAccess("messaging", policy))
}

func TestCheckPermissionUseCase_SuspendedUser_ReturnsDenied(t *testing.T) {
    mockRepo := new(MockUserPermissionRepository)
    mockRepo.On("FindByUserID", "user-123").Return(&UserPermission{
        Status: "SUSPENDED",
    }, nil)
    mockAudit := new(MockAuditLogRepository)
    mockAudit.On("Save", mock.Anything).Return(nil)

    uc := NewCheckPermissionUseCase(mockRepo, nil, nil, mockAudit)
    output, err := uc.Execute(ctx, CheckPermissionInput{
        UserID: "user-123", Action: "upload", ResourceType: "media",
    })

    assert.NoError(t, err)
    assert.False(t, output.Allowed)
    assert.Equal(t, "ACCOUNT_SUSPENDED", output.Reason)
}
```

## 8. エラーハンドリング

| ドメインエラー | HTTPステータス | ユーザーメッセージ |
| --- | --- | --- |
| ErrUserNotFound | 404 Not Found | User not found |
| ErrAccountSuspended | 403 Forbidden | Your account has been suspended |
| ErrInsufficientSystemRole | 403 Forbidden | You do not have permission to perform this action |
| ErrInsufficientOrgRole | 403 Forbidden | You do not have the required role in this organization |
| ErrFeatureNotAvailable | 403 Forbidden | This feature is not available on your current plan |
| ErrRateLimitExceeded | 429 Too Many Requests | Too many requests. Please try again later. |
| ErrGeoPolicyViolation | 403 Forbidden | Data cannot be stored in the requested region |
| ErrCannotSuspendSuperUser | 400 Bad Request | Cannot suspend a superuser account |
| ErrLastOwnerCannotLeave | 400 Bad Request | Organization must have at least one owner |

## 9. 未決事項

| # | 質問 | ステータス |
| --- | --- | --- |
| 1 | UserPermissionのRedisキャッシュTTLは何分が適切か？ | Open |
| 2 | gRPCのCheckPermissionのタイムアウトは100msで十分か？ | Open |
| 3 | AuditLogはMySQLに保存するか、将来的にS3/OCI Object Storageに移行すべきか | Open |
| 4 | サブスクリプションティアのdowngrade時の猶予期間設定 | Open |
| 5 | GDPR対応でデータ削除要求が来た場合、AuditLogも削除対象か | Open |
| 6 | 既存のCore ServiceのUserテーブルにあるsystem_roleの移行 | In Progress |
