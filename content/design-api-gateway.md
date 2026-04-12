---
title: "API Gateway Design"
weight: 15
---

# API Gateway Module (recuerdo-api-gateway)

**作成者**: Akira · **作成日**: 2026-04-13 · **ステータス**: Draft

---

## 1. 概要

### 目的

recuerdoの全マイクロサービスへの単一エントリポイントとして、JWT認証・権限チェック・ルーティング・レート制限・WebSocketプロキシを一元管理するドメイン層設計書。各マイクロサービスの内部APIを外部に直接公開せず、ゲートウェイで抽象化することでバックエンドの変更をフロントエンドに影響させない。

### ビジネスコンテキスト

解決する問題:

- マイクロサービスが増えるにつれAPIが散在し管理が困難になる
- 認証・権限チェック・レート制限ロジックが各サービスに重複実装される
- フロントエンド（iOS/Web）が複数のサービスエンドポイントを直接管理する必要がある

Key User Stories:

- iOSアプリ開発者として、単一のAPIエンドポイントに対してリクエストを送るだけで適切なサービスに振り分けてほしい
- バックエンド開発者として、新しいマイクロサービスを追加する際にフロントエンドのコード変更なしにゲートウェイのルーティング設定だけで対応したい
- セキュリティ担当として、全リクエストの認証・権限チェックを一箇所で管理したい

## 2. エンティティ層（ドメイン）

### ドメインモデル

| エンティティ | 説明 | 主要属性 |
| --- | --- | --- |
| RouteDefinition | パスパターンから上流サービスへのルーティングルール | path_prefix, upstream_url, protocol, auth_required, permission_check, required_role?, timeout_ms |
| AuthenticatedRequest | JWT検証済みリクエストのコンテキスト | user_id, system_role, trace_id, original_path, method, headers, body |
| RateLimitWindow | ユーザー/IP単位のスライディングウィンドウカウンター | key, count, window_start, ttl |
| BlockedToken | 明示的に無効化されたJWT | jti, user_id, expires_at |
| CircuitBreakerState | 上流サービスへのサーキットブレーカー状態 | upstream_name, state (CLOSED/OPEN/HALF_OPEN), failure_count, last_failure_at, next_attempt_at |

### 値オブジェクト

| 値オブジェクト | 説明 | バリデーションルール |
| --- | --- | --- |
| JWTClaims | Cognito JWTのペイロード | sub・exp・iss が必須 |
| TraceID | W3C Trace Context形式のトレースID | traceparent形式 |
| UpstreamURL | 上流サービスのURL | http:// または ws:// スキームのみ |
| RateLimitKey | レート制限のRedisキー | rate_limit:{user_id}:{window} |

### ドメインルール / 不変条件

- auth_required=trueのルートはJWT検証なしに上流サービスに転送してはならない
- permission_check=trueのルートはPermission Serviceの承認なしに転送してはならない
- BlockedTokensに存在するJTIを持つリクエストは403を返さなければならない
- サーキットブレーカーがOPEN状態の上流サービスへはリクエストを転送してはならない
- レート制限超過のリクエストには必ず429と適切なRetry-Afterヘッダーを返す
- 全リクエストにtraceIDを付与して下流に伝播しなければならない
- ゲートウェイはレスポンスボディを変更してはならない（透過的プロキシ）

### エンティティ定義（コードスケッチ）

```go
type RouteDefinition struct {
    PathPrefix    string
    UpstreamURL   string
    Protocol      string // HTTP or WS
    AuthRequired  bool
    PermCheck     bool
    RequiredRole  *string
    TimeoutMs     int
}

func (r *RouteDefinition) Validate() error {
    if r.PathPrefix == "" { return ErrInvalidPathPrefix }
    if !strings.HasPrefix(r.UpstreamURL, "http") &&
       !strings.HasPrefix(r.UpstreamURL, "ws") {
        return ErrInvalidUpstreamURL
    }
    if r.TimeoutMs <= 0 { return ErrInvalidTimeout }
    return nil
}

type CircuitBreakerState struct {
    UpstreamName  string
    State         string // CLOSED / OPEN / HALF_OPEN
    FailureCount  int
    LastFailureAt time.Time
    NextAttemptAt time.Time
}

func (c *CircuitBreakerState) ShouldAllow() bool {
    switch c.State {
    case "CLOSED":    return true
    case "OPEN":      return time.Now().After(c.NextAttemptAt)
    case "HALF_OPEN": return true
    default:          return false
    }
}
```

## 3. ユースケース層（アプリケーション）

### ユースケース一覧

| ユースケース | 入力DTO | 出力DTO | 説明 |
| --- | --- | --- | --- |
| ProcessRequest | ProcessRequestInput{http.Request, route} | ProcessRequestOutput{upstream_response} | リクエスト処理パイプライン全体のオーケストレーション |
| AuthenticateRequest | AuthenticateRequestInput{authorization_header} | AuthenticateRequestOutput{jwt_claims, user_id} | JWT検証・BlockedTokensチェック |
| CheckRateLimit | CheckRateLimitInput{user_id?, ip, endpoint} | CheckRateLimitOutput{allowed, remaining, reset_at} | レート制限チェック |
| CheckPermission | CheckPermissionInput{user_id, path, method, required_role?} | CheckPermissionOutput{allowed, reason} | Permission Service への権限チェック委譲 |
| RouteRequest | RouteRequestInput{authenticated_request, route} | RouteRequestOutput{upstream_response} | 上流サービスにプロキシ |
| ProxyWebSocket | ProxyWebSocketInput{ws_conn, route, user_id} | ProxyWebSocketOutput{} | WebSocket透過プロキシ |
| BlockToken | BlockTokenInput{jti, user_id, expires_at} | BlockTokenOutput{success} | JWTをblocked_tokensに追加 |

### ProcessRequest — 主要ユースケース詳細

**トリガー**: iOSアプリ/WebアプリからのHTTPリクエスト

**フロー**:

1. RouteMatchingPort.Match(path, method) でRouteDefinitionを取得 — マッチなし → 404
2. リクエストサイズチェック (最大50MB) — 超過 → 413
3. auth_required=true の場合: JWT検証 → 失敗 → 401
4. permission_check=true の場合: レート制限 → 超過 → 429、権限チェック → DENIED → 403
5. CircuitBreakerStatePort.Check(upstream_name) — OPEN → 503
6. リクエストヘッダーに X-User-Id, traceparent, X-Forwarded-For を付与
7. 上流サービスにプロキシ — タイムアウト → 504
8. レスポンスをそのままクライアントに返す

**注意事項**: 全フローのオーバーヘッド目標: P99 50ms以内

### リポジトリ・サービスポート

```go
type RouteMatchingPort interface {
    Match(path, method string) (*RouteDefinition, error)
    Reload(ctx context.Context) (int, error)
}

type BlockedTokenRepository interface {
    Exists(ctx context.Context, jti string) (bool, error)
    Add(ctx context.Context, token BlockedToken) error
}

type RateLimitRepository interface {
    Check(ctx context.Context, key RateLimitKey, limit int, window time.Duration) (bool, int, time.Time, error)
}

type CircuitBreakerStatePort interface {
    Check(ctx context.Context, upstreamName string) (*CircuitBreakerState, error)
    RecordSuccess(ctx context.Context, upstreamName string) error
    RecordFailure(ctx context.Context, upstreamName string) error
}

type JWTVerifierPort interface {
    Verify(ctx context.Context, token string) (*JWTClaims, error)
}

type PermissionPort interface {
    CheckPermission(ctx context.Context, userID, path, method string, requiredRole *string) (bool, string, error)
}
```

## 4. インターフェースアダプタ層

### コントローラ / ハンドラ

| コントローラ | ルート/トリガー | ユースケース |
| --- | --- | --- |
| HTTPGatewayHandler | 全HTTPリクエスト (/*) | ProcessRequestUseCase |
| WebSocketGatewayHandler | WebSocket /ws/* | ProxyWebSocketUseCase |
| HealthHandler | GET /health | ヘルスチェック |
| MetricsHandler | GET /metrics | Prometheusメトリクス |
| SQSConsumer | Queue: permission.user_suspended | BlockTokenUseCase |
| ConfigMapWatcher | ConfigMap変更検知 (fsnotify) | ReloadRoutesUseCase |

### リポジトリ実装

| ポートインターフェース | 実装クラス | データストア |
| --- | --- | --- |
| RouteMatchingPort | YAMLRouteRepository | ConfigMap (YAML, fsnotifyでホットリロード) |
| BlockedTokenRepository | RedisBlockedTokenRepository | Redis 7.x |
| RateLimitRepository | RedisSlidingWindowRepository | Redis 7.x |
| CircuitBreakerStatePort | RedisCircuitBreakerRepository | Redis 7.x |

## 5. インフラストラクチャ層

Go 1.22 + net/http + gorilla/websocket + httputil.ReverseProxy。Redis 7.x のみ（ステートレス設計）。ルーティング設定はKubernetes ConfigMap (YAML)。

### 主要ライブラリ

| ライブラリ | 目的 | レイヤー |
| --- | --- | --- |
| golang-jwt/jwt/v5 | JWT検証 | Adapter |
| lestrrat-go/jwx/v2 | JWKS取得・公開鍵キャッシュ | Infrastructure |
| gorilla/websocket | WebSocketプロキシ | Infrastructure |
| go-redis/v9 | BlockedTokens・レート制限 | Infrastructure |
| google.golang.org/grpc | Permission Service gRPCクライアント | Infrastructure |
| fsnotify/fsnotify | ConfigMap変更検知 | Infrastructure |
| uber-go/fx | 依存性注入 | Infrastructure |
| go.opentelemetry.io/otel | 分散トレーシング | Infrastructure |

## 6. ディレクトリ構成

```
recuerdo-api-gateway/
├── cmd/server/main.go
├── internal/
│   ├── domain/
│   │   ├── entity/
│   │   │   ├── route_definition.go
│   │   │   ├── authenticated_request.go
│   │   │   ├── rate_limit_window.go
│   │   │   ├── blocked_token.go
│   │   │   └── circuit_breaker_state.go
│   │   ├── valueobject/
│   │   ├── event/domain_events.go
│   │   └── errors.go
│   ├── usecase/
│   │   ├── process_request.go
│   │   ├── authenticate_request.go
│   │   ├── check_rate_limit.go
│   │   ├── check_permission.go
│   │   ├── route_request.go
│   │   ├── proxy_websocket.go
│   │   ├── block_token.go
│   │   └── reload_routes.go
│   ├── adapter/
│   │   ├── http/gateway_handler.go
│   │   ├── websocket/proxy_handler.go
│   │   ├── queue/sqs_consumer.go
│   │   └── config/configmap_watcher.go
│   └── infrastructure/
│       ├── redis/
│       ├── cognito/jwt_verifier.go
│       ├── grpc/permission_adapter.go
│       ├── proxy/
│       └── sqs/
├── config/routing_rules.yaml
└── k8s/configmap.yaml
```

## 7. テスト戦略

| レイヤー | テスト種別 | モック戦略 |
| --- | --- | --- |
| Domain | Unit test | 外部依存なし |
| UseCase | Unit test | mockeryで全ポートをモック |
| Adapter (HTTP) | Integration test | httptest.Server でモック |
| Adapter (WebSocket) | Integration test | gorilla/websocket テストクライアント |
| Infrastructure (Redis) | Integration test | testcontainers-go |
| Security | Penetration test | OWASP ZAP自動スキャン |

### テストコード例

```go
func TestCircuitBreakerState_ShouldAllow_WhenOpen(t *testing.T) {
    cb := &CircuitBreakerState{
        State: "OPEN", NextAttemptAt: time.Now().Add(30 * time.Second),
    }
    assert.False(t, cb.ShouldAllow())
}

func TestProcessRequest_BlockedToken_Returns401(t *testing.T) {
    mockJWT := new(MockJWTVerifierPort)
    mockJWT.On("Verify", "Bearer token").Return(&JWTClaims{Sub: "user-1", JTI: "jti-123"}, nil)
    mockBlocked := new(MockBlockedTokenRepository)
    mockBlocked.On("Exists", "jti-123").Return(true, nil)

    uc := NewAuthenticateRequestUseCase(mockJWT, mockBlocked)
    _, err := uc.Execute(ctx, AuthenticateRequestInput{AuthHeader: "Bearer token"})
    assert.ErrorIs(t, err, ErrTokenRevoked)
}
```

## 8. エラーハンドリング

| ドメインエラー | HTTPステータス | ユーザーメッセージ |
| --- | --- | --- |
| ErrRouteNotFound | 404 | The requested endpoint does not exist |
| ErrMissingAuthHeader | 401 | Authorization header is required |
| ErrInvalidJWT | 401 | Invalid or malformed authentication token |
| ErrExpiredJWT | 401 | Authentication token has expired |
| ErrTokenRevoked | 401 | Authentication token has been revoked |
| ErrRateLimitExceeded | 429 | Too many requests |
| ErrPermissionDenied | 403 | You do not have permission |
| ErrCircuitBreakerOpen | 503 | Service temporarily unavailable |
| ErrUpstreamTimeout | 504 | The request timed out |
| ErrRequestTooLarge | 413 | Request body exceeds maximum size |

## 9. 未決事項

| # | 質問 | ステータス |
| --- | --- | --- |
| 1 | 既存beta APIからの移行方針 | Open |
| 2 | Permission Service障害時のFail-Open条件 | Open |
| 3 | JWKS キャッシュTTL 300秒の妥当性 | Open |
| 4 | Redis障害時のFail-Open/Closed方針 | Open |
| 5 | WebSocketプロキシ時の上流障害ハンドリング | Open |
